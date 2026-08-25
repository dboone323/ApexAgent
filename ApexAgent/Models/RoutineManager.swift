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
    weak var modelContext: ModelContext?

    /// The BotManager used to route routine execution messages.
    weak var botManager: BotManager?

    /// All persisted routines, refreshed from disk on demand.
    var routines: [Routine] = []

    // MARK: - Timer scheduler for time-interval routines

    /// The backing timer used by `startScheduledRoutines` / `stopScheduledRoutines`.
    private var schedulerTimer: Timer?
    private var scheduledRoutines: [Routine] = []

    // MARK: - Load / Persist / Toggle / Delete

    func loadRoutines() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<Routine>(
            sortBy: [SortDescriptor(\Routine.createdAt, order: .forward)]
        )
        do {
            routines = try context.fetch(descriptor)
        } catch {
            print("⚠️ [RoutineManager] Failed to load routines: \\(error.localizedDescription)")
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
            print("⚠️ [RoutineManager] No BotManager — cannot execute routine '\\(routine.name)'")
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

        // Open a session for the target bot if one doesn't exist, send the
        // message (fire-and-forget), then poll for the assistant response.
        botManager.openConversation(with: targetBot)
        botManager.sendMessageTo(targetBot, text: prompt)

        // Poll for the assistant message to land (generation ~7s on-device).
        // This is a Phase 2c simplification — the real async path uses the
        // session's message stream / onUpdate callback.
        let pollInterval = TimeInterval(4)
        let maxPolls = 8
        for _ in 0..<maxPolls {
            try? await Task.sleep(for: .seconds(pollInterval))
            let session = botManager.session(for: targetBot)
            if let lastMsg = session.messages.last(where: { $0.role == .assistant }),
               !lastMsg.content.isEmpty && !lastMsg.isStreaming {
                return lastMsg.content
            }
        }
        return nil
    }

    func runNow(_ routine: Routine) async {
        _ = await execute(routine)
    }

    // MARK: - Scheduled execution

    /// Starts the Timer-based scheduler for all enabled `.timeInterval` routines.
    func startScheduledRoutines() {
        scheduledRoutines = routines.filter { $0.enabled && $0.trigger == .timeInterval && $0.scheduledMinutes > 0 }
        guard !scheduledRoutines.isEmpty else { return }
        runScheduledTick()
        let interval = Double(scheduledRoutines.map { $0.scheduledMinutes }.min() ?? 15) * 60.0
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.runScheduledTick()
            }
        }
    }

    func stopScheduledRoutines() {
        schedulerTimer?.invalidate()
        schedulerTimer = nil
        scheduledRoutines = []
    }

    private func runScheduledTick() {
        for routine in scheduledRoutines where routine.enabled {
            Task { _ = await self.execute(routine) }
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
