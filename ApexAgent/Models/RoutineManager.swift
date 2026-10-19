import Foundation
import SwiftData
import Observation
import AppKit
import SwiftUI

// MARK: - RoutineManager: discovers, persists, and executes Routines

/// RoutineManager is the runtime service for Routines.  It owns the persisted
/// routine registry, exposes a "Run now" entry point, and (for time-based
/// routines) keeps a lightweight Timer-based scheduler so they fire on schedule.
///
/// Execution is routed through the shared BotManager: `execute(_:)` picks the
/// target Bot, sends the routine's prompt, and captures the assistant response
/// once generation completes.  Outcome-reactive triggers (`.onError`/`.onSuccess`)
/// are dispatched by an external caller (e.g. ReflectionManager or a tool
/// result handler) when the relevant event is detected.
@MainActor
final class RoutineManager: Observable {
    static let shared = RoutineManager()

    /// The SwiftData context used to persist routine definitions.
    var modelContext: ModelContext?

    /// The BotManager used to route routine execution messages.
    weak var botManager: BotManager?

    /// All persisted routines, refreshed from disk on demand.
    var routines: [Routine] = []

    // MARK: - Durable Automation Receipts

    var recentRuns: [RoutineRun] = []
    private static let maxRunsRetained = 200
    private static var runsFileURL: URL {
        ApexAgentStoragePaths.directory("routine_runs").appendingPathComponent("runs.json")
    }

    init() {
        loadRuns()
    }

    func loadRuns() {
        let file = Self.runsFileURL
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoded = try JSONDecoder().decode([RoutineRun].self, from: data)
            recentRuns = decoded
        } catch {
            AppLog.error(.routine, "⚠️ Failed to load routine runs: \(error)")
        }
    }

    func saveRuns() {
        let file = Self.runsFileURL
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(recentRuns)
            try data.write(to: file, options: [.atomic])
        } catch {
            AppLog.error(.routine, "⚠️ Failed to save routine runs: \(error)")
        }
    }

    func recordRun(_ run: RoutineRun) {
        if let idx = recentRuns.firstIndex(where: { $0.id == run.id }) {
            recentRuns[idx] = run
        } else {
            recentRuns.insert(run, at: 0)
            if recentRuns.count > Self.maxRunsRetained {
                recentRuns.removeLast(recentRuns.count - Self.maxRunsRetained)
            }
        }
        saveRuns()
    }

    func clearRuns() {
        recentRuns.removeAll()
        saveRuns()
    }

    func runReceipts(for routineId: UUID? = nil) -> [RoutineRun] {
        if let routineId {
            return recentRuns.filter { $0.routineId == routineId }
        }
        return recentRuns
    }

    // MARK: - Timer scheduler for time-interval and cron routines

    /// The backing timer used by `startScheduledRoutines` / `stopScheduledRoutines`.
    private var cronHeartbeatTimer: Timer?
    private var scheduledRoutines: [Routine] = []
    private var lastRunTimes: [String: Date] = [:]

    // MARK: - Load / Persist / Toggle / Delete

    func loadRoutines() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Routine>(
            sortBy: [SortDescriptor(\Routine.createdAt, order: .forward)]
        )
        do {
            routines = try context.fetch(descriptor)
        } catch {
            AppLog.error(.routine, "⚠️ Failed to load routines: \(error.localizedDescription)")
            routines = []
        }
    }

    func save(_ routine: Routine) {
        guard let context = modelContext else { return }
        context.insert(routine)
        try? context.save()
        SpotlightIndexer.indexRoutine(
            id: routine.stableUUID.uuidString,
            name: routine.name,
            descriptionText: routine.descriptionText,
            trigger: routine.trigger.rawValue
        )
        loadRoutines()
    }

    func delete(_ routine: Routine) {
        guard let context = modelContext else { return }
        let routineId = routine.stableUUID.uuidString
        context.delete(routine)
        try? context.save()
        SpotlightIndexer.removeRoutine(id: routineId)
        loadRoutines()
    }

    func toggle(_ routine: Routine) {
        routine.enabled.toggle()
        routine.updatedAt = Date()
        try? modelContext?.save()
        loadRoutines()
    }

    // MARK: - Execution

    /// Executes a routine immediately by sending its prompt to the target Bot
    /// and capturing the assistant's response.
    ///
    /// The routine's `descriptionText` is treated as `<BotName>: <prompt>` when
    /// it contains a colon; otherwise the default Apex Bot is used.
    ///
    /// - Parameter routine: the routine to run.
    /// - Returns: the assistant's response text, or `nil` if execution failed.
    func execute(_ routine: Routine) async -> String? {
        guard let botManager = botManager else {
            AppLog.error(.routine, "⚠️ No BotManager — cannot execute routine '\(routine.name)'")
            let failedRun = RoutineRun(
                routineId: routine.stableUUID,
                routineName: routine.name,
                prompt: routine.descriptionText,
                trigger: routine.trigger,
                status: .failed,
                startedAt: Date(),
                finishedAt: Date(),
                output: nil,
                error: "BotManager unavailable"
            )
            recordRun(failedRun)
            return nil
        }

        // Parse "<BotName>: <prompt>" convention or fall back to default bot.
        let (targetBot, prompt): (BotProfile, String)
        if let colonIdx = routine.descriptionText.firstIndex(of: ":") {
            let candidate = String(routine.descriptionText[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            if let bot = botManager.botByName(candidate) {
                targetBot = bot
                prompt = String(routine.descriptionText[routine.descriptionText.index(after: colonIdx)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                targetBot = botManager.allBots.first ?? defaultApexBot()
                prompt = routine.descriptionText
            }
        } else {
            targetBot = botManager.allBots.first ?? defaultApexBot()
            prompt = routine.descriptionText
        }

        guard !prompt.isEmpty else {
            let failedRun = RoutineRun(
                routineId: routine.stableUUID,
                routineName: routine.name,
                prompt: "",
                botId: targetBot.id,
                trigger: routine.trigger,
                status: .failed,
                startedAt: Date(),
                finishedAt: Date(),
                output: nil,
                error: "Routine prompt is empty"
            )
            recordRun(failedRun)
            return nil
        }

        var run = RoutineRun(
            routineId: routine.stableUUID,
            routineName: routine.name,
            prompt: prompt,
            botId: targetBot.id,
            trigger: routine.trigger,
            status: .running,
            startedAt: Date()
        )
        recordRun(run)

        let session = botManager.session(for: targetBot)
        let response = await session.executeIsolatedTurn(prompt: prompt)

        run.finishedAt = Date()
        if let response = response {
            run.status = .completed
            run.output = response
        } else {
            run.status = .failed
            run.error = "Bot execution returned no response or timed out."
        }
        recordRun(run)

        return response
    }

    func runNow(_ routine: Routine) async {
        _ = await execute(routine)
    }

    // MARK: - Scheduled execution

    /// Starts the Timer-based scheduler for all enabled time-interval and cron routines.
    func startScheduledRoutines() {
        scheduledRoutines = routines.filter { $0.enabled && ($0.trigger == .timeInterval || $0.trigger == .cron) }
        guard !scheduledRoutines.isEmpty else { return }
        
        let now = Date()
        for routine in scheduledRoutines {
            if lastRunTimes[routine.name] == nil {
                lastRunTimes[routine.name] = now
            }
        }
        
        TickerScheduler.shared.register(
            id: "RoutineManager.heartbeat",
            policy: PollPolicy(baseInterval: 60.0, minInterval: 60.0, maxInterval: 120.0)
        ) { [weak self] in
            Task { @MainActor in
                self?.evaluateHeartbeat()
            }
            return true
        }
        TickerScheduler.shared.start(checkIntervalSeconds: 5.0)
    }

    func stopScheduledRoutines() {
        TickerScheduler.shared.unregister(id: "RoutineManager.heartbeat")
        cronHeartbeatTimer?.invalidate()
        cronHeartbeatTimer = nil
        scheduledRoutines = []
    }

    private func evaluateHeartbeat() {
        let now = Date()
        for routine in scheduledRoutines where routine.enabled {
            if routine.trigger == .timeInterval {
                guard routine.scheduledMinutes > 0 else { continue }
                let interval = TimeInterval(routine.scheduledMinutes * 60)
                let lastRun = lastRunTimes[routine.name] ?? Date.distantPast
                if now.timeIntervalSince(lastRun) >= interval {
                    lastRunTimes[routine.name] = now
                    Task { _ = await self.execute(routine) }
                }
            } else if routine.trigger == .cron {
                guard let cronExpr = routine.cronExpression,
                      let schedule = try? CronSchedule(expression: cronExpr) else { continue }
                if schedule.matches(date: now) {
                    lastRunTimes[routine.name] = now
                    Task { _ = await self.execute(routine) }
                }
            }
        }
    }

    // MARK: - Outcome-reactive dispatch

    /// Called by an external observer (e.g. ReflectionManager, tool result
    /// handler) when a failure or success signal is detected.  Runs every
    /// enabled `.onError` / `.onSuccess` routine.
    func dispatchReaction(signal: RoutineTrigger, contextMessage: String) async {
        let candidates = routines.filter { $0.enabled && $0.trigger == signal }
        for routine in candidates {
            _ = await execute(routine)
        }
    }

    // MARK: - Message-reactive dispatch

    /// Evaluates and executes any enabled `.onMessage` routines matching the incoming text.
    @discardableResult
    func dispatchOnMessage(text: String, fromBotId: UUID? = nil) async -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        loadRoutines()
        let candidates = routines.filter { $0.enabled && $0.trigger == .onMessage }
        var outputs: [String] = []
        for routine in candidates {
            if let filter = routine.messageFilter, !filter.isEmpty {
                let matches = trimmed.localizedCaseInsensitiveContains(filter)
                if !matches { continue }
            }
            if let out = await execute(routine) {
                outputs.append(out)
            }
        }
        return outputs
    }

    // MARK: - Webhook dispatch (O5)

    /// Fire the enabled `.webhook` routine matching `routineName`. Returns the
    /// assistant response, or nil when no such routine exists / no BotManager
    /// is wired / generation did not produce output in time.
    @discardableResult
    func dispatchWebhook(routineName: String) async -> String? {
        loadRoutines()
        guard let routine = routines.first(where: {
            $0.enabled && $0.trigger == .webhook && $0.name == routineName
        }) else {
            AppLog.error(.routine, "⚠️ No enabled .webhook routine named '\(routineName)'")
            return nil
        }
        return await execute(routine)
    }

    // MARK: - Helpers

    private func defaultApexBot() -> BotProfile {
        BotProfile(
            name: "Apex",
            title: "General Assistant",
            descriptionText: "You are Apex, a helpful AI assistant running on this Mac.",
            avatarName: "person.fill",
            isPinned: false
        )
    }

    // MARK: - Markdown Summaries

    public func exportRoutinesSummaryAsMarkdown() -> String {
        guard !routines.isEmpty else {
            return "No automated routines configured."
        }

        var md = "### ⏱️ Configured Automation Routines\n\n"
        md += "| Routine Name | Enabled | Schedule / Trigger | Last Updated |\n"
        md += "|---|---|---|---|\n"

        for r in routines {
            let enabledBadge = r.enabled ? "🟢 Enabled" : "⚪️ Disabled"
            let triggerText = r.effectiveScheduleDescription
            md += "| **\(r.name)** | \(enabledBadge) | `\(triggerText)` | `\(r.updatedAt)` |\n"
        }
        return md
    }

    public func exportRoutineRunsSummary(limit: Int = 20) -> String {
        guard !recentRuns.isEmpty else {
            return "No routine execution receipts recorded."
        }

        let runs = Array(recentRuns.prefix(limit))
        var md = "### 📜 Automation Routine Run Receipts (\(runs.count) entries)\n\n"
        md += "| Routine Name | Status | Duration (s) | Started At |\n"
        md += "|---|---|---|---|\n"

        for run in runs {
            let statusBadge: String
            switch run.status {
            case .completed: statusBadge = "✅ Completed"
            case .failed: statusBadge = "❌ Failed"
            case .running: statusBadge = "⏳ Running"
            case .queued: statusBadge = "📋 Queued"
            case .cancelled: statusBadge = "⏹️ Cancelled"
            }
            let durationSeconds = (run.finishedAt?.timeIntervalSince(run.startedAt)) ?? 0.0
            let durationStr = String(format: "%.2f", durationSeconds)
            md += "| **\(run.routineName)** | \(statusBadge) | `\(durationStr)` | `\(run.startedAt)` |\n"
        }
        return md
    }

}