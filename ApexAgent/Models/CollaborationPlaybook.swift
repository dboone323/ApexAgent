import Foundation

// MARK: - Collaboration Playbook Models

/// Defines the built-in preset types for multi-agent collaboration playbooks.
public enum PlaybookPresetKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case fullPRReviewLoop = "full_pr_review_loop"
    case issueToPatchPipeline = "issue_to_patch_pipeline"
    case weeklyStandupAndRetrospective = "weekly_standup_retro"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fullPRReviewLoop:
            return "Full PR Review Loop"
        case .issueToPatchPipeline:
            return "Issue-to-Patch Pipeline"
        case .weeklyStandupAndRetrospective:
            return "Weekly Standup & Retrospective"
        }
    }

    public var defaultDescription: String {
        switch self {
        case .fullPRReviewLoop:
            return "End-to-end pull request review workflow: intake triage, dual architecture and security review in parallel, automated test verification, approval gating, and executive summary."
        case .issueToPatchPipeline:
            return "Automated bugfix pipeline: issue triage, root cause analysis, surgical patch design, test execution, and human review gating."
        case .weeklyStandupAndRetrospective:
            return "Autonomous team standup: all bot specialists generate individual activity reports in parallel, followed by Chief of Staff synthesis and action item extraction."
        }
    }
}

/// Execution dispatch mode for a playbook stage.
public enum PlaybookDispatchMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case sequential = "sequential"
    case parallel = "parallel"
}

/// A required role within a playbook workflow.
public struct PlaybookRoleRequirement: Identifiable, Codable, Sendable, Hashable, Equatable {
    public let id: String
    public var title: String
    public var description: String
    public var suggestedAvatar: String

    public init(
        id: String,
        title: String,
        description: String = "",
        suggestedAvatar: String = "person.fill"
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.suggestedAvatar = suggestedAvatar
    }

    // Standard role archetypes matching the 5-bot roster
    public static let chiefOfStaff = PlaybookRoleRequirement(
        id: "chief_of_staff",
        title: "Chief of Staff",
        description: "Executive coordinator, delegation manager, and outcome synthesizer.",
        suggestedAvatar: "person.crop.square.fill"
    )

    public static let codeArchitect = PlaybookRoleRequirement(
        id: "code_architect",
        title: "Code Architect",
        description: "Senior software engineer specializing in code quality, architecture patterns, and diff reviews.",
        suggestedAvatar: "chevron.left.forwardslash.chevron.right"
    )

    public static let researcher = PlaybookRoleRequirement(
        id: "researcher",
        title: "Researcher",
        description: "Technical researcher specializing in security audits, documentation, and root cause analysis.",
        suggestedAvatar: "magnifyingglass"
    )

    public static let automator = PlaybookRoleRequirement(
        id: "automator",
        title: "Automator",
        description: "System automator specializing in build verification, test suite execution, and CI/CD operations.",
        suggestedAvatar: "terminal.fill"
    )

    public static let generalAssistant = PlaybookRoleRequirement(
        id: "general_assistant",
        title: "General Assistant",
        description: "General assistant bot for supporting general queries and operations.",
        suggestedAvatar: "bolt.fill"
    )

    public static let apex = generalAssistant
}

/// Snapshot of an assigned bot participant in a playbook execution.
public struct PlaybookParticipant: Identifiable, Codable, Sendable, Equatable, Hashable {
    public let id: UUID
    public var name: String
    public var title: String
    public var roleId: String
    public var isChiefOfStaff: Bool
    public var avatarName: String

    public init(
        id: UUID = UUID(),
        name: String,
        title: String = "",
        roleId: String = "",
        isChiefOfStaff: Bool = false,
        avatarName: String = "person.fill"
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.roleId = roleId
        self.isChiefOfStaff = isChiefOfStaff
        self.avatarName = avatarName
    }

    @MainActor
    init(from bot: BotProfile, roleId: String = "") {
        self.id = bot.id
        self.name = bot.name
        self.title = bot.title
        self.roleId = roleId.isEmpty ? bot.title : roleId
        self.isChiefOfStaff = bot.isChiefOfStaff
        self.avatarName = bot.avatarName
    }
}

/// Defines a discrete stage within a collaboration playbook.
public struct PlaybookStageDefinition: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var description: String
    public var dispatchMode: PlaybookDispatchMode
    public var requiredRoles: [PlaybookRoleRequirement]
    public var promptTemplate: String
    public var requiresApproval: Bool
    public var approvalDescription: String?

    public var title: String {
        get { name }
        set { name = newValue }
    }

    public var requiresApprovalGate: Bool {
        get { requiresApproval }
        set { requiresApproval = newValue }
    }

    public var requiredRoleIds: [String] {
        requiredRoles.map(\.id)
    }

    public init(
        id: String,
        name: String,
        description: String = "",
        dispatchMode: PlaybookDispatchMode = .sequential,
        requiredRoles: [PlaybookRoleRequirement],
        promptTemplate: String,
        requiresApproval: Bool = false,
        approvalDescription: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.dispatchMode = dispatchMode
        self.requiredRoles = requiredRoles
        self.promptTemplate = promptTemplate
        self.requiresApproval = requiresApproval
        self.approvalDescription = approvalDescription
    }

    public init(
        id: String,
        name: String,
        description: String = "",
        dispatchMode: PlaybookDispatchMode = .sequential,
        requiredRole: PlaybookRoleRequirement,
        promptTemplate: String,
        requiresApproval: Bool = false,
        approvalDescription: String? = nil
    ) {
        self.init(
            id: id,
            name: name,
            description: description,
            dispatchMode: dispatchMode,
            requiredRoles: [requiredRole],
            promptTemplate: promptTemplate,
            requiresApproval: requiresApproval,
            approvalDescription: approvalDescription
        )
    }
}

/// Approval status for human-in-the-loop gates.
public enum PlaybookApprovalStatus: String, Codable, Sendable, Equatable {
    case pending = "pending"
    case approved = "approved"
    case rejected = "rejected"
}

/// Human-in-the-loop approval card raised at stage approval gates.
public struct PlaybookApprovalCard: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let playbookId: UUID
    public let stageId: String
    public let stageTitle: String
    public var summary: String
    public var proposedActions: [String]
    public let createdAt: Date
    public var status: PlaybookApprovalStatus
    public var resolutionNotes: String?

    public var stageName: String { stageTitle }

    public init(
        id: UUID = UUID(),
        playbookId: UUID,
        stageId: String,
        stageTitle: String,
        summary: String,
        proposedActions: [String] = [],
        createdAt: Date = Date(),
        status: PlaybookApprovalStatus = .pending,
        resolutionNotes: String? = nil
    ) {
        self.id = id
        self.playbookId = playbookId
        self.stageId = stageId
        self.stageTitle = stageTitle
        self.summary = summary
        self.proposedActions = proposedActions
        self.createdAt = createdAt
        self.status = status
        self.resolutionNotes = resolutionNotes
    }
}

/// Lifecycle status of a peer delegation event.
public enum PlaybookDelegationStatus: String, Codable, Sendable, Equatable {
    case pendingApproval = "pending_approval"
    case inProgress = "in_progress"
    case completed = "completed"
    case failed = "failed"
}

/// Records a peer delegation event between bots during playbook execution.
public struct PlaybookDelegationEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let playbookId: UUID
    public let stageId: String
    public let fromBotId: UUID
    public let fromBotName: String
    public let toBotId: UUID
    public let toBotName: String
    public let action: String
    public let message: String
    public var status: PlaybookDelegationStatus
    public var resultSummary: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        playbookId: UUID,
        stageId: String,
        fromBotId: UUID,
        fromBotName: String,
        toBotId: UUID,
        toBotName: String,
        action: String,
        message: String,
        status: PlaybookDelegationStatus = .inProgress,
        resultSummary: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.playbookId = playbookId
        self.stageId = stageId
        self.fromBotId = fromBotId
        self.fromBotName = fromBotName
        self.toBotId = toBotId
        self.toBotName = toBotName
        self.action = action
        self.message = message
        self.status = status
        self.resultSummary = resultSummary
        self.timestamp = timestamp
    }
}

/// Output from an individual bot's turn within a stage.
public struct PlaybookBotResult: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let botId: UUID
    public let botName: String
    public let roleId: String
    public let output: String
    public let duration: TimeInterval
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        botId: UUID,
        botName: String,
        roleId: String,
        output: String,
        duration: TimeInterval = 0,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.botId = botId
        self.botName = botName
        self.roleId = roleId
        self.output = output
        self.duration = duration
        self.timestamp = timestamp
    }
}

/// Status of a stage execution.
public enum PlaybookStageStatus: String, Codable, Sendable, Equatable {
    case success = "success"
    case failed = "failed"
    case skipped = "skipped"
}

/// Result produced by a playbook stage.
public struct PlaybookStageResult: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let stageId: String
    public let stageName: String
    public let dispatchMode: PlaybookDispatchMode
    public var botResults: [PlaybookBotResult]
    public var combinedOutput: String
    public var duration: TimeInterval
    public let completedAt: Date
    public var status: PlaybookStageStatus

    public init(
        id: UUID = UUID(),
        stageId: String,
        stageName: String,
        dispatchMode: PlaybookDispatchMode,
        botResults: [PlaybookBotResult] = [],
        combinedOutput: String = "",
        duration: TimeInterval = 0,
        completedAt: Date = Date(),
        status: PlaybookStageStatus = .success
    ) {
        self.id = id
        self.stageId = stageId
        self.stageName = stageName
        self.dispatchMode = dispatchMode
        self.botResults = botResults
        self.combinedOutput = combinedOutput
        self.duration = duration
        self.completedAt = completedAt
        self.status = status
    }
}

/// Overall execution status of a playbook runner.
public enum PlaybookExecutionStatus: Codable, Sendable, Equatable {
    case idle
    case running(stageId: String, stageIndex: Int)
    case waitingForApproval(card: PlaybookApprovalCard)
    case completed(report: PlaybookExecutionReport)
    case failed(error: String)
    case cancelled
}

/// Comprehensive report generated after playbook execution concludes.
public struct PlaybookExecutionReport: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let playbookId: UUID
    public let playbookName: String
    public let presetKind: PlaybookPresetKind?
    public let contextInput: String
    public var stageResults: [PlaybookStageResult]
    public var delegationEvents: [PlaybookDelegationEvent]
    public var approvalCards: [PlaybookApprovalCard]
    public var finalOutput: String
    public var totalDuration: TimeInterval
    public let startedAt: Date
    public var completedAt: Date
    public var isSuccessful: Bool

    public init(
        id: UUID = UUID(),
        playbookId: UUID,
        playbookName: String,
        presetKind: PlaybookPresetKind? = nil,
        contextInput: String,
        stageResults: [PlaybookStageResult] = [],
        delegationEvents: [PlaybookDelegationEvent] = [],
        approvalCards: [PlaybookApprovalCard] = [],
        finalOutput: String = "",
        totalDuration: TimeInterval = 0,
        startedAt: Date = Date(),
        completedAt: Date = Date(),
        isSuccessful: Bool = true
    ) {
        self.id = id
        self.playbookId = playbookId
        self.playbookName = playbookName
        self.presetKind = presetKind
        self.contextInput = contextInput
        self.stageResults = stageResults
        self.delegationEvents = delegationEvents
        self.approvalCards = approvalCards
        self.finalOutput = finalOutput
        self.totalDuration = totalDuration
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.isSuccessful = isSuccessful
    }
}

// MARK: - Collaboration Playbook Template

/// Represents a multi-stage autonomous collaboration playbook.
public struct CollaborationPlaybook: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var presetKind: PlaybookPresetKind?
    public var name: String
    public var description: String
    public var version: String
    public var roles: [PlaybookRoleRequirement]
    public var stages: [PlaybookStageDefinition]

    public init(
        id: UUID = UUID(),
        presetKind: PlaybookPresetKind? = nil,
        name: String,
        description: String = "",
        version: String = "1.0",
        roles: [PlaybookRoleRequirement],
        stages: [PlaybookStageDefinition]
    ) {
        self.id = id
        self.presetKind = presetKind
        self.name = name
        self.description = description
        self.version = version
        self.roles = roles
        self.stages = stages
    }

    // MARK: - Built-in Presets

    public static func preset(for kind: PlaybookPresetKind) -> CollaborationPlaybook {
        switch kind {
        case .fullPRReviewLoop:
            return fullPRReviewLoop
        case .issueToPatchPipeline:
            return issueToPatchPipeline
        case .weeklyStandupAndRetrospective:
            return weeklyStandupAndRetrospective
        }
    }

    public static var builtInPresets: [CollaborationPlaybook] {
        [fullPRReviewLoop, issueToPatchPipeline, weeklyStandupAndRetrospective]
    }

    /// Built-in Preset 1: Full PR Review Loop
    public static var fullPRReviewLoop: CollaborationPlaybook {
        let roles: [PlaybookRoleRequirement] = [
            .chiefOfStaff,
            .codeArchitect,
            .researcher,
            .automator
        ]

        let stages: [PlaybookStageDefinition] = [
            PlaybookStageDefinition(
                id: "stage_pr_intake",
                name: "PR Intake & Scope Analysis",
                description: "Chief of Staff inspects PR description, branch metadata, and prepares review agenda.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Analyze the pull request context and establish the review plan:\n{input}"
            ),
            PlaybookStageDefinition(
                id: "stage_dual_review",
                name: "Dual Architecture & Security Review",
                description: "Code Architect inspects diff for design patterns and correctness; Researcher audits security and dependencies in parallel.",
                dispatchMode: .parallel,
                requiredRoles: [.codeArchitect, .researcher],
                promptTemplate: "Perform specialized inspection based on the intake analysis:\n{previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_ci_verification",
                name: "Patch & CI Verification",
                description: "Automator runs test suite, checks build logs, and validates CI pipeline status.",
                dispatchMode: .sequential,
                requiredRole: .automator,
                promptTemplate: "Verify build integrity and automated test execution for the reviewed changes:\n{previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_merge_approval_gate",
                name: "Merge & Deploy Approval Gate",
                description: "Human supervisor approval required before final verdict submission.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Approval checkpoint: Review findings and verify readiness to proceed.",
                requiresApproval: true,
                approvalDescription: "Human sign-off required: Review architectural, security, and CI test results before generating final PR verdict."
            ),
            PlaybookStageDefinition(
                id: "stage_executive_summary",
                name: "Executive Summary & PR Comments",
                description: "Chief of Staff compiles all findings into a unified PR review comment with final verdict.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Synthesize all specialist reviews into a structured executive PR review comment with clear verdict:\n{previousOutput}"
            )
        ]

        return CollaborationPlaybook(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            presetKind: .fullPRReviewLoop,
            name: "Full PR Review Loop",
            description: PlaybookPresetKind.fullPRReviewLoop.defaultDescription,
            version: "1.0",
            roles: roles,
            stages: stages
        )
    }

    /// Built-in Preset 2: Issue-to-Patch Pipeline
    public static var issueToPatchPipeline: CollaborationPlaybook {
        let roles: [PlaybookRoleRequirement] = [
            .chiefOfStaff,
            .researcher,
            .codeArchitect,
            .automator
        ]

        let stages: [PlaybookStageDefinition] = [
            PlaybookStageDefinition(
                id: "stage_issue_triage",
                name: "Issue Triage & Workstream Assignment",
                description: "Chief of Staff triages incoming issue report, checks priority, and assigns workstreams.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Triage the following issue report, determine reproduction requirements, and coordinate specialists:\n{input}"
            ),
            PlaybookStageDefinition(
                id: "stage_root_cause",
                name: "Root Cause & Reproduction",
                description: "Researcher investigates error traces, reproduces conditions, and identifies affected files.",
                dispatchMode: .sequential,
                requiredRole: .researcher,
                promptTemplate: "Investigate root cause and document reproduction steps for:\n{previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_patch_authoring",
                name: "Patch Authoring",
                description: "Code Architect authors surgical code fixes and generates unified diff patch.",
                dispatchMode: .sequential,
                requiredRole: .codeArchitect,
                promptTemplate: "Author the surgical code patch resolving the identified root cause:\n{previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_test_benchmark",
                name: "Test Execution & Benchmark",
                description: "Automator applies patch in sandbox, executes unit/regression tests, and benchmarks performance.",
                dispatchMode: .sequential,
                requiredRole: .automator,
                promptTemplate: "Execute test suite against the authored patch and record benchmark results:\n{previousOutput}"
            ),
            PlaybookStageDefinition(
                id: "stage_patch_approval_gate",
                name: "Review & Merge Approval Gate",
                description: "Human supervisor review of proposed patch and test results prior to release.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Human review checkpoint for patch merging.",
                requiresApproval: true,
                approvalDescription: "Human sign-off required: Review authored patch, test suite results, and benchmark metrics before merging."
            )
        ]

        return CollaborationPlaybook(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            presetKind: .issueToPatchPipeline,
            name: "Issue-to-Patch Pipeline",
            description: PlaybookPresetKind.issueToPatchPipeline.defaultDescription,
            version: "1.0",
            roles: roles,
            stages: stages
        )
    }

    /// Built-in Preset 3: Weekly Standup & Retrospective
    public static var weeklyStandupAndRetrospective: CollaborationPlaybook {
        let roles: [PlaybookRoleRequirement] = [
            .chiefOfStaff,
            .codeArchitect,
            .researcher,
            .automator,
            .generalAssistant
        ]

        let stages: [PlaybookStageDefinition] = [
            PlaybookStageDefinition(
                id: "stage_standup_reports",
                name: "Simultaneous Team Standup Reports",
                description: "All 5 bot specialists generate progress summaries, current blockers, and upcoming goals simultaneously in parallel.",
                dispatchMode: .parallel,
                requiredRoles: roles,
                promptTemplate: "Generate your weekly activity report, key accomplishments, current blockers, and next priorities for:\n{input}"
            ),
            PlaybookStageDefinition(
                id: "stage_standup_synthesis",
                name: "Synthesis, Blockers & Action Items",
                description: "Chief of Staff synthesizes all team reports into an executive standup briefing with prioritized action items.",
                dispatchMode: .sequential,
                requiredRole: .chiefOfStaff,
                promptTemplate: "Synthesize all team member standup reports into an executive standup briefing with risk highlights and action items:\n{previousOutput}"
            )
        ]

        return CollaborationPlaybook(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            presetKind: .weeklyStandupAndRetrospective,
            name: "Weekly Standup & Retrospective",
            description: PlaybookPresetKind.weeklyStandupAndRetrospective.defaultDescription,
            version: "1.0",
            roles: roles,
            stages: stages
        )
    }

    public static var weeklyStandupAndRetro: CollaborationPlaybook {
        weeklyStandupAndRetrospective
    }

    // MARK: - Serialization Helpers

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(from data: Data) throws -> CollaborationPlaybook {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CollaborationPlaybook.self, from: data)
    }
}

// MARK: - Playbook Participant Assigner

/// Heuristic role-to-bot mapping across available BotProfile instances with robust fallback.
public struct PlaybookParticipantAssigner: Sendable {

    /// Assigns bot profiles for each required role in the playbook.
    @MainActor
    static func assignParticipants(
        for playbook: CollaborationPlaybook,
        availableBots: [BotProfile]
    ) -> [PlaybookRoleRequirement: BotProfile] {
        assignParticipants(roles: playbook.roles, availableBots: availableBots)
    }

    /// Assigns bot profiles for an array of required roles against available bots.
    @MainActor
    static func assignParticipants(
        roles: [PlaybookRoleRequirement],
        availableBots: [BotProfile]
    ) -> [PlaybookRoleRequirement: BotProfile] {
        var assignments: [PlaybookRoleRequirement: BotProfile] = [:]
        var assignedBotIds: Set<UUID> = []

        guard !availableBots.isEmpty else {
            return assignments
        }

        // Pass 1: Exact heuristic matching for each role
        for role in roles {
            if let matchedBot = findBestMatch(for: role, in: availableBots, excluding: assignedBotIds) {
                assignments[role] = matchedBot
                assignedBotIds.insert(matchedBot.id)
            }
        }

        // Pass 2: Fallback for any unassigned roles
        for role in roles where assignments[role] == nil {
            if let remainingBot = availableBots.first(where: { !assignedBotIds.contains($0.id) }) {
                assignments[role] = remainingBot
                assignedBotIds.insert(remainingBot.id)
            } else {
                if let fallbackBot = availableBots.first(where: { $0.isChiefOfStaff }) ?? availableBots.first {
                    assignments[role] = fallbackBot
                }
            }
        }

        return assignments
    }

    /// Assigns participant snapshots (Sendable) for playbook runners.
    @MainActor
    static func assignParticipantSnapshots(
        for playbook: CollaborationPlaybook,
        availableBots: [BotProfile]
    ) -> [PlaybookRoleRequirement: PlaybookParticipant] {
        let profileMap = assignParticipants(for: playbook, availableBots: availableBots)
        var snapshotMap: [PlaybookRoleRequirement: PlaybookParticipant] = [:]
        for (role, bot) in profileMap {
            snapshotMap[role] = PlaybookParticipant(from: bot, roleId: role.id)
        }
        return snapshotMap
    }

    /// Finds the best matching BotProfile for a given role requirement.
    @MainActor
    private static func findBestMatch(
        for role: PlaybookRoleRequirement,
        in availableBots: [BotProfile],
        excluding excludedIds: Set<UUID>
    ) -> BotProfile? {
        let candidates = availableBots.filter { !excludedIds.contains($0.id) }
        let roleId = role.id.lowercased()

        if roleId == "chief_of_staff" || roleId == "chiefofstaff" {
            // Prefer bot with isChiefOfStaff == true, or name containing "chief", or title containing "coordinator"
            return candidates.first(where: { $0.isChiefOfStaff })
                ?? candidates.first(where: { $0.name.localizedCaseInsensitiveContains("chief") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("coordinator") })
        }

        if roleId == "code_architect" || roleId == "architect" || roleId == "developer" {
            // Prefer name/title containing "architect", "engineer", "developer", "code"
            return candidates.first(where: { $0.name.localizedCaseInsensitiveContains("architect") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("engineer") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("architect") })
                ?? candidates.first(where: { $0.name.localizedCaseInsensitiveContains("developer") })
        }

        if roleId == "researcher" || roleId == "research" || roleId == "analyst" {
            // Prefer name/title containing "researcher", "research", "analyst", "security"
            return candidates.first(where: { $0.name.localizedCaseInsensitiveContains("researcher") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("research") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("analyst") })
                ?? candidates.first(where: { $0.descriptionText.localizedCaseInsensitiveContains("research") })
        }

        if roleId == "automator" || roleId == "system" || roleId == "devops" {
            // Prefer name/title containing "automator", "system", "terminal", "automation"
            return candidates.first(where: { $0.name.localizedCaseInsensitiveContains("automator") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("automator") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("system") })
                ?? candidates.first(where: { $0.descriptionText.localizedCaseInsensitiveContains("terminal") })
        }

        if roleId == "general_assistant" || roleId == "apex" || roleId == "general" {
            // Prefer name "Apex" or "General Assistant"
            return candidates.first(where: { $0.name.localizedCaseInsensitiveContains("apex") })
                ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains("general") })
        }

        // Generic fallback by role name matching
        return candidates.first(where: { $0.name.localizedCaseInsensitiveContains(role.title) })
            ?? candidates.first(where: { $0.title.localizedCaseInsensitiveContains(role.title) })
    }
}
