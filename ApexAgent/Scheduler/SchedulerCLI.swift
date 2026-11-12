import Foundation
import Darwin

/// CLI handler for `ApexAgent scheduler` subcommands.
public enum SchedulerCLI {
    private static func printOut(_ message: String) {
        fputs("\(message)\n", Darwin.stdout)
    }

    private static func printErr(_ message: String) {
        fputs("\(message)\n", Darwin.stderr)
    }

    public static func run(arguments: [String]) async -> Int32 {
        guard let action = arguments.first else {
            printUsage()
            return 0
        }

        let subArgs = Array(arguments.dropFirst())

        switch action {
        case "cron":
            return await handleCron(arguments: subArgs)
        case "heartbeat":
            return await handleHeartbeat(arguments: subArgs)
        case "trigger":
            return await handleTrigger(arguments: subArgs)
        case "status":
            return await handleStatus()
        case "--help", "-h", "help":
            printUsage()
            return 0
        default:
            printErr("Unknown scheduler action '\(action)'. Run 'ApexAgent scheduler --help' for usage.")
            return 64
        }
    }

    private static func printUsage() {
        printOut("""
        Usage: ApexAgent scheduler <action> [options]

        Actions:
          cron        Exact cron scheduler operations & live verification
          heartbeat   Run a judgement pass over a checklist file
          trigger     Monitor and dispatch real event triggers (file/mail/calendar/webhook/lan-peer)
          status      Display status and statistics of all scheduler components

        Cron options:
          --expr <expression>    Cron expression (e.g. '* * * * *')
          --wait-fire <seconds>  Wait for exact scheduled fire event
          --eval-now             Evaluate due jobs at current time

        Heartbeat options:
          --checklist <path>     Path to Markdown checklist file (required)
          --update               Update original checklist file in place
          --json                 Output report in JSON format

        Trigger options:
          --type <type>          Trigger type: file, webhook, lan-peer, mail, calendar
          --path <path>          Target path (for file trigger)
          --port <port>          TCP port (for webhook or lan-peer trigger)
          --endpoint <name>      Endpoint name (for webhook trigger)
          --wait <seconds>       Duration to wait for event
        """)
    }

    private static func handleCron(arguments: [String]) async -> Int32 {
        var expr = "* * * * *"
        var waitFireSeconds: Int = 0
        var evalNow = false

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--expr":
                if i + 1 < arguments.count {
                    expr = arguments[i + 1]
                    i += 1
                }
            case "--wait-fire":
                if i + 1 < arguments.count, let sec = Int(arguments[i + 1]) {
                    waitFireSeconds = sec
                    i += 1
                }
            case "--eval-now":
                evalNow = true
            default:
                break
            }
            i += 1
        }

        let scheduler = ExactCronScheduler.shared

        do {
            let firedBox = LockedBox<[Date]>([])
            let jobId = try await scheduler.register(name: "cli-verification-job", expression: expr) {
                firedBox.withLock { dates in
                    dates.append(Date())
                }
            }

            defer {
                Task {
                    await scheduler.unregister(id: jobId)
                }
            }

            if evalNow {
                let count = await scheduler.evaluateDueJobs(at: Date())
                printOut("Evaluated due jobs: \(count) executed.")
                return 0
            }

            if waitFireSeconds > 0 {
                await scheduler.start()
                printOut("Started ExactCronScheduler. Waiting up to \(waitFireSeconds)s for exact cron fire ('\(expr)')...")
                let deadline = Date().addingTimeInterval(TimeInterval(waitFireSeconds))
                while Date() < deadline {
                    let count = firedBox.withLock { $0.count }
                    if count > 0 {
                        let dates = firedBox.withLock { $0 }
                        printOut("✅ SUCCESS: Exact cron job fired at exact time: \(dates.first?.description ?? "")")
                        await scheduler.stop()
                        return 0
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                await scheduler.stop()
                printErr("❌ TIMEOUT: Exact cron job did not fire within \(waitFireSeconds)s.")
                return 1
            } else {
                guard let job = await scheduler.job(id: jobId) else { return 1 }
                printOut("Registered cron job '\(job.name)' with next run at: \(job.nextRunDate?.description ?? "none")")
                return 0
            }
        } catch {
            printErr("Cron scheduler error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleHeartbeat(arguments: [String]) async -> Int32 {
        var checklistPath: String?
        var updateInPlace = false
        var jsonOutput = false

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--checklist":
                if i + 1 < arguments.count {
                    checklistPath = arguments[i + 1]
                    i += 1
                }
            case "--update":
                updateInPlace = true
            case "--json":
                jsonOutput = true
            default:
                break
            }
            i += 1
        }

        guard let path = checklistPath else {
            printErr("Error: Missing required --checklist <path> argument.")
            return 64
        }

        let resolvedURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: resolvedURL.path) else {
            printErr("Error: Checklist file not found at '\(resolvedURL.path)'.")
            return 66
        }

        do {
            let report = try await HeartbeatJudgementPass.shared.runPass(
                checklistURL: resolvedURL,
                updateInPlace: updateInPlace
            )

            if jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(report)
                if let str = String(data: data, encoding: .utf8) {
                    printOut(str)
                }
            } else {
                printOut(report.formatAsMarkdown())
            }

            return report.overallPassed ? 0 : 1
        } catch {
            printErr("Heartbeat judgement pass error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleTrigger(arguments: [String]) async -> Int32 {
        var typeStr = "file"
        var path: String?
        var port: UInt16?
        var endpoint: String = "test-webhook"
        var waitSeconds: Int = 5

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--type":
                if i + 1 < arguments.count {
                    typeStr = arguments[i + 1].lowercased()
                    i += 1
                }
            case "--path":
                if i + 1 < arguments.count {
                    path = arguments[i + 1]
                    i += 1
                }
            case "--port":
                if i + 1 < arguments.count, let p = UInt16(arguments[i + 1]) {
                    port = p
                    i += 1
                }
            case "--endpoint":
                if i + 1 < arguments.count {
                    endpoint = arguments[i + 1]
                    i += 1
                }
            case "--wait":
                if i + 1 < arguments.count, let w = Int(arguments[i + 1]) {
                    waitSeconds = w
                    i += 1
                }
            default:
                break
            }
            i += 1
        }

        let kind: EventTriggerKind
        switch typeStr {
        case "file": kind = .file
        case "webhook": kind = .webhook
        case "lan-peer", "lanpeer": kind = .lanPeer
        case "mail": kind = .mail
        case "calendar": kind = .calendar
        default:
            printErr("Unknown trigger type '\(typeStr)'. Valid: file, webhook, lan-peer, mail, calendar")
            return 64
        }

        let config = EventTriggerConfig(
            kind: kind,
            identifier: endpoint,
            targetPath: path,
            port: port ?? (kind == .webhook ? 1338 : 1339),
            secretToken: nil,
            pollIntervalSeconds: 1.0
        )

        let coordinator = EventTriggerCoordinator.shared
        let receivedBox = LockedBox<[EventTriggerPayload]>([])

        do {
            let triggerId = try await coordinator.register(config: config) { payload in
                receivedBox.withLock { events in
                    events.append(payload)
                }
            }

            try await coordinator.start(id: triggerId)
            printOut("Started listening for real \(kind.rawValue) trigger. Waiting up to \(waitSeconds)s...")

            let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
            while Date() < deadline {
                let count = receivedBox.withLock { $0.count }
                if count > 0 {
                    let first = receivedBox.withLock { $0.first! }
                    printOut("✅ SUCCESS: Received \(kind.rawValue) trigger: \(first.summary)")
                    await coordinator.stop(id: triggerId)
                    return 0
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            await coordinator.stop(id: triggerId)
            printErr("Timed out waiting for \(kind.rawValue) event.")
            return 1
        } catch {
            printErr("Event trigger error: \(error.localizedDescription)")
            return 1
        }
    }

    private static func handleStatus() async -> Int32 {
        let cronJobs = await ExactCronScheduler.shared.allJobs()
        let recentPasses = await HeartbeatJudgementPass.shared.recentReports
        let triggerStats = await EventTriggerCoordinator.shared.allStats()

        printOut("# ⏱️ ApexAgent Scheduler Trio Status\n")

        printOut("## 1. Exact Cron Scheduler")
        printOut("- Registered Jobs: \(cronJobs.count)")
        for j in cronJobs {
            printOut("  - `\(j.name)`: expr='\(j.expression)', runs=\(j.runCount), next=\(j.nextRunDate?.description ?? "none")")
        }
        if cronJobs.isEmpty {
            printOut("  (No cron jobs active)")
        }

        printOut("\n## 2. Heartbeat Judgement Pass")
        printOut("- Recent Passes: \(recentPasses.count)")
        if let latest = recentPasses.first {
            printOut("  - Latest: `\(latest.checklistPath)` at \(latest.timestamp), status=\(latest.overallPassed ? "PASS" : "FAIL")")
        }

        printOut("\n## 3. Event Triggers")
        printOut("- Registered Triggers: \(triggerStats.count)")
        for s in triggerStats {
            printOut("  - [\(s.kind.rawValue)] '\(s.identifier)': fires=\(s.fireCount), liveVerified=\(s.isLiveVerified)")
        }

        return 0
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
