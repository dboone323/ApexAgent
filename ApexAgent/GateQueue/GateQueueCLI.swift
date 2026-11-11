import Foundation
import Darwin

/// CLI handler for `ApexAgent gate-queue` subcommands.
public enum GateQueueCLI {
    private static func printOut(_ message: String) {
        fputs("\(message)\n", Darwin.stdout)
    }

    public static func run(arguments: [String]) async -> Int32 {
        guard let action = arguments.first else {
            printUsage()
            return 0
        }

        let subArgs = Array(arguments.dropFirst())

        switch action {
        case "submit":
            return await handleSubmit(arguments: subArgs)
        case "run":
            return await handleRun(arguments: subArgs)
        case "status":
            return await handleStatus(arguments: subArgs)
        case "recover":
            return await handleRecover(arguments: subArgs)
        case "--help", "-h", "help":
            printUsage()
            return 0
        default:
            fputs("Unknown gate-queue action '\(action)'. Run 'ApexAgent gate-queue --help' for usage.\n", Darwin.stderr)
            return 64
        }
    }

    private static func printUsage() {
        printOut("""
        Usage: ApexAgent gate-queue <action> [options]

        Actions:
          submit    Drop a new gate job spec into a project's runs/gate-queue/ folder
          run       Start or drain the gate queue worker across registered projects
          status    Display the status of pending, in-progress, and completed jobs
          recover   Scan for and report any stale in-progress jobs from crashed runs

        Submit options:
          --project <path>    Target project directory (required)
          --job <name>        Job name (e.g. test-deep, lint) (required)
          --baseline <path>   Baseline file path (optional)
          --cmd <argv...>     Gate command argv array (must be last flag)

        Run options:
          --project <path>    Register project directory (can specify multiple)
          --once              Drain pending jobs and exit (default is single pass if specified)
          --interval <sec>    Polling interval in seconds (default: 60)
        """)
    }

    private static func handleSubmit(arguments: [String]) async -> Int32 {
        var project: String?
        var job: String?
        var baseline: String?
        var cmdArgs: [String] = []

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--project", i + 1 < arguments.count {
                project = arguments[i + 1]
                i += 2
            } else if arg == "--job", i + 1 < arguments.count {
                job = arguments[i + 1]
                i += 2
            } else if arg == "--baseline", i + 1 < arguments.count {
                baseline = arguments[i + 1]
                i += 2
            } else if arg == "--cmd" {
                cmdArgs = Array(arguments.dropFirst(i + 1))
                break
            } else {
                i += 1
            }
        }

        guard let project = project, !project.isEmpty else {
            fputs("Error: --project <path> is required.\n", Darwin.stderr)
            return 64
        }
        guard let job = job, !job.isEmpty else {
            fputs("Error: --job <name> is required.\n", Darwin.stderr)
            return 64
        }
        guard !cmdArgs.isEmpty else {
            fputs("Error: --cmd <argv...> is required.\n", Darwin.stderr)
            return 64
        }

        let spec = GateJobSpec(
            jobName: job,
            targetProject: URL(fileURLWithPath: project).path,
            gateCommand: cmdArgs,
            baselineFile: baseline
        )

        do {
            let fileURL = try spec.submit()
            printOut("✅ Submitted gate job '\(job)' to \(fileURL.path)")
            return 0
        } catch {
            fputs("Error submitting gate job: \(error.localizedDescription)\n", Darwin.stderr)
            return 1
        }
    }

    private static func handleRun(arguments: [String]) async -> Int32 {
        var projects: [String] = []
        var once = false
        var interval: TimeInterval = 60

        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--project", i + 1 < arguments.count {
                projects.append(arguments[i + 1])
                i += 2
            } else if arg == "--once" {
                once = true
                i += 1
            } else if arg == "--interval", i + 1 < arguments.count {
                interval = Double(arguments[i + 1]) ?? 60
                i += 2
            } else {
                i += 1
            }
        }

        if projects.isEmpty {
            // Default to current directory
            projects.append(FileManager.default.currentDirectoryPath)
        }

        let worker = GateQueueWorker(
            registeredProjects: projects.map { URL(fileURLWithPath: $0) }
        )

        await worker.recoverStaleInProgressJobs()

        if once {
            do {
                let reports = try await worker.drainQueue()
                printOut("Drained \(reports.count) gate job(s).")
                for report in reports {
                    let status = report.exitCode == 0 ? "PASS" : "FAIL"
                    printOut("- [\(status)] \(report.jobSpec.jobName) (exit code \(report.exitCode)) in \(String(format: "%.2f", report.duration))s")
                }
                let failedCount = reports.filter { $0.exitCode != 0 }.count
                return failedCount > 0 ? 1 : 0
            } catch {
                fputs("Error during queue run: \(error.localizedDescription)\n", Darwin.stderr)
                return 1
            }
        } else {
            printOut("Starting GateQueueWorker polling across \(projects.count) project(s) every \(Int(interval))s...")
            do {
                _ = try await worker.runPollLoop(intervalSeconds: interval) { false }
                return 0
            } catch {
                fputs("Worker loop stopped: \(error.localizedDescription)\n", Darwin.stderr)
                return 1
            }
        }
    }

    private static func handleStatus(arguments: [String]) async -> Int32 {
        var projects: [String] = []
        var i = 0
        while i < arguments.count {
            if arguments[i] == "--project", i + 1 < arguments.count {
                projects.append(arguments[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        if projects.isEmpty {
            projects.append(FileManager.default.currentDirectoryPath)
        }

        for path in projects {
            let projectURL = URL(fileURLWithPath: path)
            let queueDir = GateJobSpec.queueDirectory(for: projectURL.path)
            printOut("Project: \(projectURL.path)")
            printOut("Queue Directory: \(queueDir.path)")

            guard let items = try? FileManager.default.contentsOfDirectory(atPath: queueDir.path) else {
                printOut("  (queue directory does not exist or is empty)")
                continue
            }

            let pending = items.filter { $0.hasSuffix(".json") && !$0.contains(".in-progress") && !$0.contains(".completed") && !$0.contains(".stale-recovered") }
            let inProgress = items.filter { $0.contains(".in-progress") }
            let completed = items.filter { $0.contains(".completed") }
            let reports = items.filter { $0.hasSuffix("-report.md") }

            printOut("  Pending: \(pending.count)")
            for p in pending { printOut("    - \(p)") }
            printOut("  In Progress: \(inProgress.count)")
            for ip in inProgress { printOut("    - \(ip)") }
            printOut("  Completed: \(completed.count)")
            printOut("  Reports: \(reports.count)")
        }

        return 0
    }

    private static func handleRecover(arguments: [String]) async -> Int32 {
        var projects: [String] = []
        var i = 0
        while i < arguments.count {
            if arguments[i] == "--project", i + 1 < arguments.count {
                projects.append(arguments[i + 1])
                i += 2
            } else {
                i += 1
            }
        }
        if projects.isEmpty {
            projects.append(FileManager.default.currentDirectoryPath)
        }

        let worker = GateQueueWorker(registeredProjects: projects.map { URL(fileURLWithPath: $0) })
        let recoveries = await worker.recoverStaleInProgressJobs()
        printOut("Recovered \(recoveries.count) stale in-progress job(s).")
        for rec in recoveries {
            printOut("- Job '\(rec.jobName)' in \(rec.projectPath) -> \(rec.recoveredFileURL.lastPathComponent)")
        }
        return 0
    }
}
