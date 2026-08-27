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
            print("⚠️ [RoutineManager] Failed to load routines: \(error.localizedDescription)")
            routines = []
        }
    }

    func save(_ routine: Routine) {
        guard let context = modelContext else { return }
        context.insert(routine)
        try? context.save()
        loadRoutines()
    }

    func delete(_ routine: Routine) {
        guard let context = modelContext else { return }
        context.delete(routine)
        try? context.save()
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
            print("⚠️ [RoutineManager] No BotManager — cannot execute routine '\(routine.name)'")
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

        guard !prompt.isEmpty else { return nil }

        let session = botManager.session(for: targetBot)
        let response = await session.sendMessageAsync(prompt)
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
        
        cronHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateHeartbeat()
            }
        }
    }

    func stopScheduledRoutines() {
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
            print("⚠️ [RoutineManager] No enabled .webhook routine named '\(routineName)'")
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
}
