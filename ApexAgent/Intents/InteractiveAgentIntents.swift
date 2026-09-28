import AppIntents
import Foundation
import SwiftData

// MARK: - TriggerRoutineIntent

@available(macOS 13.0, *)
public struct TriggerRoutineIntent: AppIntent {
    public static var title: LocalizedStringResource { "Trigger Routine" }
    public static var description: IntentDescription {
        IntentDescription("Triggers a saved ApexAgent routine by name.")
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Run Routine \(\.$routineName)")
    }

    @Parameter(title: "Routine Name", description: "Name of the routine to execute.")
    public var routineName: String

    public init() {
        self.routineName = ""
    }

    public init(routineName: String) {
        self.routineName = routineName
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = routineName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.invalidName("Routine name cannot be empty.")
        }

        let manager = RoutineManager.shared
        guard let routine = manager.routines.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return .result(value: "Routine '\(trimmed)' not found in active catalog.")
        }

        guard let output = await manager.execute(routine) else {
            throw IntentError.executionFailed("Routine '\(routine.name)' failed to execute — check that a BotManager is active and the routine prompt is non-empty.")
        }
        return .result(value: "Routine '\(routine.name)' executed successfully:\n\(output)")
    }

    public enum IntentError: LocalizedError {
        case invalidName(String)
        case executionFailed(String)
        public var errorDescription: String? {
            switch self {
            case .invalidName(let msg): return msg
            case .executionFailed(let msg): return msg
            }
        }
    }
}

// MARK: - InspectAgentStatusIntent

@available(macOS 13.0, *)
public struct InspectAgentStatusIntent: AppIntent {
    public static var title: LocalizedStringResource { "Inspect Agent Status" }
    public static var description: IntentDescription {
        IntentDescription("Retrieves the live operational status and active bot count of ApexAgent.")
    }

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let botCount = AppDelegate.sharedOrchestrator.botManager?.bots.count ?? 0
        let activeSessions = AppDelegate.sharedOrchestrator.botManager?.sessions.count ?? 0
        let routinesCount = RoutineManager.shared.routines.count

        let report = """
        ApexAgent Status: ONLINE
        Active Bots: \(botCount)
        Running Sessions: \(activeSessions)
        Registered Routines: \(routinesCount)
        Engine: Native Apple AFM / Ollama Hybrid
        """
        return .result(value: report)
    }
}

// MARK: - ExecutePlaybookIntent

@available(macOS 13.0, *)
public struct ExecutePlaybookIntent: AppIntent {
    public static var title: LocalizedStringResource { "Execute Collaboration Playbook" }
    public static var description: IntentDescription {
        IntentDescription("Runs an autonomous multi-bot collaboration playbook preset.")
    }

    @Parameter(
        title: "Preset",
        description: "Playbook preset: 'pr_review', 'issue_to_patch', or 'standup'",
        default: "pr_review"
    )
    public var preset: String

    public init() {
        self.preset = "pr_review"
    }

    public init(preset: String) {
        self.preset = preset
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let selectedPreset: CollaborationPlaybook
        switch preset.lowercased() {
        case "issue_to_patch", "issue":
            selectedPreset = .issueToPatchPipeline
        case "standup", "weekly_standup":
            selectedPreset = .weeklyStandupAndRetrospective
        case "pr_review", "pr":
            fallthrough
        default:
            selectedPreset = .fullPRReviewLoop
        }

        var bots = AppDelegate.sharedOrchestrator.botManager?.bots ?? []
        if bots.isEmpty {
            let cos = BotProfile(name: "Chief of Staff", title: "Coordinator", descriptionText: "Lead", avatarName: "person.crop.square.fill")
            cos.isChiefOfStaff = true
            let arch = BotProfile(name: "Code Architect", title: "Senior Engineer", descriptionText: "Architecture", avatarName: "chevron.left.forwardslash.chevron.right")
            let res = BotProfile(name: "Researcher", title: "Researcher", descriptionText: "Research", avatarName: "magnifyingglass")
            let auto = BotProfile(name: "Automator", title: "Automator", descriptionText: "Automation", avatarName: "terminal.fill")
            bots = [cos, arch, res, auto]
        }
        // Pass botManager so the runner uses .live execution mode instead of simulation.
        // Pass onApprovalRequired that throws immediately — Siri/Shortcuts can't surface
        // a blocking desktop UI confirmation card without hanging the intent forever.
        let botManager = AppDelegate.sharedOrchestrator.botManager
        let runner = PlaybookRunner(playbook: selectedPreset, availableBots: bots, botManager: botManager)
        let report = try await runner.execute(
            contextInput: "Triggered via macOS App Intent",
            onApprovalRequired: { card in
                throw PlaybookExecutionError.approvalRejected(
                    stageId: card.stageId,
                    reason: "Stage '\(card.stageTitle)' requires human approval in the ApexAgent desktop app — cannot proceed non-interactively via Siri/Shortcuts."
                )
            }
        )

        let statusText = report.isSuccessful ? "SUCCESS" : "FAILED"
        return .result(value: "Playbook '\(selectedPreset.name)' executed: \(statusText)")
    }
}

