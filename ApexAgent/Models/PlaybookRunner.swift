import Foundation
import Observation
import SharedKit

// MARK: - Playbook Execution Errors

public enum PlaybookExecutionError: Error, LocalizedError, Equatable {
    case alreadyRunning
    case cancelled
    case approvalRejected(stageId: String, reason: String)
    case missingParticipant(roleId: String)
    case stageExecutionFailed(stageId: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "Playbook is already actively running."
        case .cancelled:
            return "Playbook execution was cancelled."
        case .approvalRejected(let stageId, let reason):
            return "Approval gate rejected at stage '\(stageId)': \(reason)"
        case .missingParticipant(let roleId):
            return "Missing assigned participant for required role: \(roleId)"
        case .stageExecutionFailed(let stageId, let reason):
            return "Stage '\(stageId)' failed execution: \(reason)"
        }
    }
}

// MARK: - Playbook Runner Class

/// Autonomous execution engine for multi-agent collaboration playbooks.
///
/// Turn execution modes:
/// - `.live`: each turn is a real agent invocation through the bot's live
///   `BotSession` (requires a `BotManager` injected at init). Production mode.
/// - `.simulated`: turns use a clearly-marked simulation stub (no `BotManager`
///   wired, or running under a test host). Used for unit tests and UI
///   previews; simulated output is explicitly labeled and must never be
///   presented as real agent work.
///
/// Features:
/// - Asynchronous sequential and parallel (`withThrowingTaskGroup`) turn dispatching.
/// - Stage-level human-in-the-loop approval cards with asynchronous pause/resume,
///   a fail-safe auto-reject timeout, and an `onApprovalRequired` callback hook.
/// - Live tracking of peer delegation events (plus an `onDelegationEvent` hook)
///   and `TraceBus` event emission.
/// - Comprehensive execution reporting with per-stage timings and bot responses.
@Observable
@MainActor
final class PlaybookRunner {

    // MARK: - Approval Resolution

    /// Internal outcome of an approval-gate suspension.
    private enum ApprovalOutcome: Sendable {
        case approved
        case rejected
        case timedOut
    }

    // MARK: - Properties

    let playbook: CollaborationPlaybook
    let participantMap: [PlaybookRoleRequirement: BotProfile]
    /// Optional live-session source. When nil, turns run in clearly-marked
    /// simulation mode. Weak to avoid a retain cycle with the owning manager.
    weak var botManager: BotManager?

    private(set) var status: PlaybookExecutionStatus = .idle
    private(set) var currentStageIndex: Int = 0
    private(set) var stageResults: [PlaybookStageResult] = []
    private(set) var delegationEvents: [PlaybookDelegationEvent] = []
    private(set) var approvalCards: [PlaybookApprovalCard] = []
    private(set) var pendingApprovalCard: PlaybookApprovalCard?
    private(set) var isCancelled: Bool = false
    /// `.live` when turns go through real bot sessions, `.simulated` otherwise.
    private(set) var executionMode: PlaybookExecutionMode = .simulated
    /// Fail-safe: an unanswered approval gate auto-rejects after this long
    /// so a stage can never hang forever with no user path to resolve it.
    /// Shorten in tests to exercise the timeout path quickly.
    var approvalTimeout: TimeInterval = 300

    private var pendingApprovalContinuation: CheckedContinuation<ApprovalOutcome, Never>?
    private var approvalTimeoutTask: Task<Void, Never>?
    private var delegationEventHandler: ((PlaybookDelegationEvent) -> Void)?
    private var lastApprovalResolutionNotes: String?
    private var lastActiveBot: BotProfile?

    /// Per-turn cap for a live agent invocation (timeout race mirroring
    /// MultiAgentDebateCoordinator).
    private static let liveTurnTimeoutNanoseconds: UInt64 = 60_000_000_000

    /// Test hosts must never fire real model calls. Mirrors BotSession's
    /// test-mode detection (a test-only behavioral gate, not a security gate).
    private static var isTestEnvironment: Bool {
        getenv("APEX_TEST_MODE") != nil
            || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
    }

    // MARK: - Initialization

    init(
        playbook: CollaborationPlaybook,
        participantMap: [PlaybookRoleRequirement: BotProfile],
        botManager: BotManager? = nil
    ) {
        self.playbook = playbook
        self.participantMap = participantMap
        self.botManager = botManager
    }

    init(
        playbook: CollaborationPlaybook,
        availableBots: [BotProfile],
        botManager: BotManager? = nil
    ) {
        self.playbook = playbook
        self.participantMap = PlaybookParticipantAssigner.assignParticipants(
            for: playbook,
            availableBots: availableBots
        )
        self.botManager = botManager
    }

    // MARK: - Primary Execution

    /// Executes the collaboration playbook end-to-end.
    ///
    /// - Parameters:
    ///   - contextInput: The initial input/context fed to the first stage.
    ///   - onApprovalRequired: PROJECT M2 contract hook, fired when an approval
    ///     card is raised so the host can surface it in UI. The runner still
    ///     suspends until `approvePendingStage`/`rejectPendingStage` is called
    ///     or the fail-safe auto-reject timeout fires.
    ///   - onDelegationEvent: PROJECT M2 contract hook, fired for every peer
    ///     delegation event as it is tracked.
    func execute(
        contextInput: String,
        onApprovalRequired: ((PlaybookApprovalCard) async throws -> Void)? = nil,
        onDelegationEvent: ((PlaybookDelegationEvent) -> Void)? = nil
    ) async throws -> PlaybookExecutionReport {
        guard case .idle = status else {
            throw PlaybookExecutionError.alreadyRunning
        }

        let startedAt = Date()
        isCancelled = false
        stageResults.removeAll()
        delegationEvents.removeAll()
        approvalCards.removeAll()
        pendingApprovalCard = nil
        lastApprovalResolutionNotes = nil
        lastActiveBot = nil
        delegationEventHandler = onDelegationEvent
        defer { delegationEventHandler = nil }

        // Live turns need a wired BotManager and a non-test host process;
        // otherwise turns are clearly-marked simulation output (tests/previews).
        executionMode = (botManager != nil && !Self.isTestEnvironment) ? .live : .simulated
        if executionMode == .simulated {
            emitTrace(
                operation: "execution_mode_simulated",
                detail: "Running in SIMULATION mode (no live BotManager wired or test host): turn outputs are placeholders, not real agent responses.",
                metadata: ["playbookId": playbook.id.uuidString]
            )
        }

        emitTrace(
            operation: "playbook_started",
            detail: "Starting playbook '\(playbook.name)' with \(playbook.stages.count) stages.",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "playbookName": playbook.name,
                "presetKind": playbook.presetKind?.rawValue ?? "custom"
            ]
        )

        var previousOutput = contextInput

        for (index, stage) in playbook.stages.enumerated() {
            guard !isCancelled else {
                status = .cancelled
                emitTrace(operation: "playbook_cancelled", detail: "Playbook execution cancelled at stage \(stage.name).")
                throw PlaybookExecutionError.cancelled
            }

            currentStageIndex = index
            status = .running(stageId: stage.id, stageIndex: index)

            emitTrace(
                operation: "stage_started",
                detail: "Starting stage [\(index + 1)/\(playbook.stages.count)]: \(stage.name) (\(stage.dispatchMode.rawValue))",
                metadata: [
                    "playbookId": playbook.id.uuidString,
                    "stageId": stage.id,
                    "stageName": stage.name,
                    "dispatchMode": stage.dispatchMode.rawValue
                ]
            )

            // Check if stage is an approval gate
            if stage.requiresApproval {
                let card = PlaybookApprovalCard(
                    playbookId: playbook.id,
                    stageId: stage.id,
                    stageTitle: stage.name,
                    summary: stage.approvalDescription ?? "Approval required for stage \(stage.name)",
                    proposedActions: [
                        "Approve and proceed to next stage",
                        "Reject and abort playbook execution"
                    ],
                    createdAt: Date(),
                    status: .pending
                )

                pendingApprovalCard = card
                approvalCards.append(card)
                status = .waitingForApproval(card: card)

                emitTrace(
                    operation: "approval_gate_paused",
                    detail: "Playbook paused at approval gate '\(stage.name)': \(card.summary)",
                    metadata: [
                        "playbookId": playbook.id.uuidString,
                        "stageId": stage.id,
                        "cardId": card.id.uuidString
                    ]
                )

                // Suspend execution until approved, rejected, or timed out.
                // The fail-safe timeout guarantees a stage can never hang
                // forever when no UI surfaces the card.
                let outcome: ApprovalOutcome = await withCheckedContinuation { (continuation: CheckedContinuation<ApprovalOutcome, Never>) in
                    self.pendingApprovalContinuation = continuation
                    let timeout = max(self.approvalTimeout, 0)
                    self.approvalTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        self?.resolveApprovalAsTimedOut()
                    }

                    // PROJECT M2 contract hook: let the host surface the card in UI.
                    // Fired after continuation registration so onApprovalRequired handlers
                    // or event listeners can resolve the card immediately without deadlocking.
                    if let hook = onApprovalRequired {
                        Task { @MainActor [weak self] in
                            do {
                                try await hook(card)
                            } catch {
                                self?.rejectPendingStage(reason: "Approval required callback failed: \(error.localizedDescription)")
                            }
                        }
                    }
                }
                approvalTimeoutTask?.cancel()
                approvalTimeoutTask = nil

                switch outcome {
                case .approved:
                    emitTrace(
                        operation: "approval_gate_resumed",
                        detail: "Approval granted for stage '\(stage.name)'. Resuming execution.",
                        metadata: ["playbookId": playbook.id.uuidString, "stageId": stage.id]
                    )

                    status = .running(stageId: stage.id, stageIndex: index)

                case .rejected, .timedOut:
                    let rejectReason: String
                    if outcome == .timedOut {
                        rejectReason = lastApprovalResolutionNotes
                            ?? "Approval timed out after \(Int(approvalTimeout))s with no response (auto-rejected)"
                    } else {
                        rejectReason = lastApprovalResolutionNotes ?? "User rejected approval gate"
                    }
                    status = .failed(error: "Approval gate rejected: \(rejectReason)")

                    emitTrace(
                        operation: "playbook_failed",
                        detail: "Playbook failed at approval gate '\(stage.name)': \(rejectReason)",
                        metadata: ["playbookId": playbook.id.uuidString, "stageId": stage.id]
                    )

                    throw PlaybookExecutionError.approvalRejected(stageId: stage.id, reason: rejectReason)
                }
            }

            // Execute the stage turns (sequential or parallel)
            let stageStart = Date()
            let interpolatedPrompt = interpolatePrompt(
                template: stage.promptTemplate,
                input: contextInput,
                previousOutput: previousOutput,
                stageName: stage.name
            )

            let botResults: [PlaybookBotResult]
            let combinedOutput: String

            switch stage.dispatchMode {
            case .sequential:
                var sequentialResults: [PlaybookBotResult] = []
                for role in stage.requiredRoles {
                    guard let bot = resolveBot(for: role) else {
                        throw PlaybookExecutionError.missingParticipant(roleId: role.id)
                    }

                    // Track peer delegation if transitioning from a different bot
                    if let previousBot = lastActiveBot, previousBot.id != bot.id {
                        trackDelegation(
                            from: previousBot,
                            to: bot,
                            stageId: stage.id,
                            action: "sequential_handoff",
                            message: "Handoff context from stage \(stage.name)"
                        )
                    }
                    lastActiveBot = bot

                    let turnStart = Date()
                    let response = await runBotTurn(
                        bot: bot,
                        roleId: role.id,
                        stageId: stage.id,
                        stageName: stage.name,
                        prompt: interpolatedPrompt
                    )
                    let duration = Date().timeIntervalSince(turnStart)

                    let turnResult = PlaybookBotResult(
                        botId: bot.id,
                        botName: bot.name,
                        roleId: role.id,
                        output: response,
                        duration: duration,
                        timestamp: Date(),
                        isSimulated: executionMode == .simulated
                    )
                    sequentialResults.append(turnResult)
                }

                botResults = sequentialResults
                combinedOutput = sequentialResults.map { "[\($0.botName)]: \($0.output)" }.joined(separator: "\n\n")

            case .parallel:
                // Swift Structured Concurrency: Execute all participant turns concurrently
                let parallelRoles = stage.requiredRoles
                var tasksResults: [PlaybookBotResult] = []

                struct ParallelTaskItem {
                    let botId: UUID
                    let botName: String
                    let roleId: String
                    let stageId: String
                    let stageName: String
                    let prompt: String
                    /// Live session when executionMode == .live; nil → simulation stub.
                    let session: BotSession?
                }

                var taskItems: [ParallelTaskItem] = []
                for role in parallelRoles {
                    guard let bot = self.resolveBot(for: role) else {
                        throw PlaybookExecutionError.missingParticipant(roleId: role.id)
                    }

                    // Track parallel delegation event
                    if let leadBot = self.resolveBot(for: .chiefOfStaff) ?? self.lastActiveBot {
                        self.trackDelegation(
                            from: leadBot,
                            to: bot,
                            stageId: stage.id,
                            action: "parallel_fan_out",
                            message: "Dispatched parallel task for stage \(stage.name)"
                        )
                    }

                    // Resolve the live session on the MainActor before fanning out;
                    // child tasks only carry Sendable snapshots (mirrors MultiAgentDebateCoordinator).
                    let liveSession: BotSession? = (executionMode == .live) ? botManager?.session(for: bot) : nil

                    taskItems.append(ParallelTaskItem(
                        botId: bot.id,
                        botName: bot.name,
                        roleId: role.id,
                        stageId: stage.id,
                        stageName: stage.name,
                        prompt: interpolatedPrompt,
                        session: liveSession
                    ))
                }

                try await withThrowingTaskGroup(of: PlaybookBotResult.self) { group in
                    for item in taskItems {
                        group.addTask {
                            let turnStart = Date()
                            let response: String
                            if let session = item.session {
                                response = await Self.runLiveTurn(session: session, botName: item.botName, prompt: item.prompt)
                            } else {
                                response = Self.generateSimulatedTurnResponse(
                                    botName: item.botName,
                                    roleId: item.roleId,
                                    stageId: item.stageId,
                                    stageName: item.stageName,
                                    prompt: item.prompt
                                )
                            }
                            let duration = Date().timeIntervalSince(turnStart)
                            return PlaybookBotResult(
                                botId: item.botId,
                                botName: item.botName,
                                roleId: item.roleId,
                                output: response,
                                duration: duration,
                                timestamp: Date(),
                                isSimulated: item.session == nil
                            )
                        }
                    }


                    for try await result in group {
                        tasksResults.append(result)
                    }
                }

                botResults = tasksResults
                combinedOutput = tasksResults.map { "[\($0.botName) - \($0.roleId)]: \($0.output)" }.joined(separator: "\n\n")
            }

            let stageDuration = Date().timeIntervalSince(stageStart)
            let stageResult = PlaybookStageResult(
                stageId: stage.id,
                stageName: stage.name,
                dispatchMode: stage.dispatchMode,
                botResults: botResults,
                combinedOutput: combinedOutput,
                duration: stageDuration,
                completedAt: Date(),
                status: .success
            )

            stageResults.append(stageResult)
            previousOutput = combinedOutput

            emitTrace(
                operation: "stage_completed",
                detail: "Stage '\(stage.name)' completed in \(String(format: "%.2f", stageDuration))s with \(botResults.count) response(s).",
                metadata: [
                    "playbookId": playbook.id.uuidString,
                    "stageId": stage.id,
                    "durationMs": String(format: "%.0f", stageDuration * 1000)
                ]
            )
        }

        let completedAt = Date()
        let totalDuration = completedAt.timeIntervalSince(startedAt)
        let finalOutput = stageResults.last?.combinedOutput ?? previousOutput

        let report = PlaybookExecutionReport(
            playbookId: playbook.id,
            playbookName: playbook.name,
            presetKind: playbook.presetKind,
            contextInput: contextInput,
            stageResults: stageResults,
            delegationEvents: delegationEvents,
            approvalCards: approvalCards,
            finalOutput: finalOutput,
            totalDuration: totalDuration,
            startedAt: startedAt,
            completedAt: completedAt,
            isSuccessful: true,
            executionMode: executionMode
        )

        status = .completed(report: report)

        emitTrace(
            operation: "playbook_completed",
            detail: "Playbook '\(playbook.name)' completed successfully in \(String(format: "%.2f", totalDuration))s.",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "totalStages": String(stageResults.count),
                "totalDelegations": String(delegationEvents.count),
                "totalDurationMs": String(format: "%.0f", totalDuration * 1000)
            ]
        )

        return report
    }

    // MARK: - Approval Card Handling

    /// Approves the currently pending stage approval card and resumes execution.
    func approvePendingStage(notes: String? = nil) {
        guard var card = pendingApprovalCard, let continuation = pendingApprovalContinuation else {
            return
        }

        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil

        card.status = .approved
        card.resolutionNotes = notes ?? "Approved by user"
        lastApprovalResolutionNotes = card.resolutionNotes
        pendingApprovalCard = nil
        pendingApprovalContinuation = nil

        // Update card in history list
        if let idx = approvalCards.firstIndex(where: { $0.id == card.id }) {
            approvalCards[idx] = card
        }

        emitTrace(
            operation: "approval_resolved",
            detail: "Approval card for stage '\(card.stageTitle)' was approved: \(card.resolutionNotes ?? "")",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "cardId": card.id.uuidString,
                "stageId": card.stageId
            ]
        )

        continuation.resume(returning: .approved)
    }

    /// Rejects the currently pending stage approval card and aborts execution.
    func rejectPendingStage(reason: String = "Rejected by user") {
        guard var card = pendingApprovalCard, let continuation = pendingApprovalContinuation else {
            return
        }

        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil

        card.status = .rejected
        card.resolutionNotes = reason
        lastApprovalResolutionNotes = reason
        pendingApprovalCard = nil
        pendingApprovalContinuation = nil

        // Update card in history list
        if let idx = approvalCards.firstIndex(where: { $0.id == card.id }) {
            approvalCards[idx] = card
        }

        emitTrace(
            operation: "approval_rejected",
            detail: "Approval card for stage '\(card.stageTitle)' was rejected: \(reason)",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "cardId": card.id.uuidString,
                "stageId": card.stageId,
                "reason": reason
            ]
        )

        continuation.resume(returning: .rejected)
    }

    /// Fail-safe: auto-rejects an approval gate that went unanswered for
    /// `approvalTimeout` seconds, so execution can never hang forever when no
    /// UI surfaces the card. Loudly traced; never auto-approves.
    private func resolveApprovalAsTimedOut() {
        guard var card = pendingApprovalCard, let continuation = pendingApprovalContinuation else {
            return
        }

        let notes = "Approval timed out after \(Int(approvalTimeout))s with no response — auto-rejected (fail-safe)"
        card.status = .rejected
        card.resolutionNotes = notes
        lastApprovalResolutionNotes = notes
        pendingApprovalCard = nil
        pendingApprovalContinuation = nil
        approvalTimeoutTask = nil

        if let idx = approvalCards.firstIndex(where: { $0.id == card.id }) {
            approvalCards[idx] = card
        }

        emitTrace(
            operation: "approval_timed_out",
            detail: "⚠️ Approval card for stage '\(card.stageTitle)' went unanswered for \(Int(approvalTimeout))s — auto-rejected. No UI resolved the card in time.",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "cardId": card.id.uuidString,
                "stageId": card.stageId,
                "timeoutSeconds": String(Int(approvalTimeout))
            ]
        )
        print("⚠️ [PlaybookRunner] Approval gate '\(card.stageTitle)' auto-rejected after \(Int(approvalTimeout))s with no response.")

        continuation.resume(returning: .timedOut)
    }

    /// Cancels active playbook execution.
    func cancel() {
        isCancelled = true
        status = .cancelled
        approvalTimeoutTask?.cancel()
        approvalTimeoutTask = nil
        if let continuation = pendingApprovalContinuation {
            pendingApprovalContinuation = nil
            pendingApprovalCard = nil
            continuation.resume(returning: .rejected)
        }
        emitTrace(
            operation: "playbook_cancelled",
            detail: "Playbook '\(playbook.name)' execution cancelled by request.",
            metadata: ["playbookId": playbook.id.uuidString]
        )
    }

    // MARK: - Helper Methods

    private func resolveBot(for role: PlaybookRoleRequirement) -> BotProfile? {
        if let exact = participantMap[role] {
            return exact
        }
        // Fallback search by role id
        if let matched = participantMap.first(where: { $0.key.id == role.id })?.value {
            return matched
        }
        return participantMap.values.first
    }

    public static func sanitizeForPrompt(_ text: String) -> String {
        var sanitized = text
        sanitized = sanitized.replacingOccurrences(of: "{input}", with: "\\{input\\}")
        sanitized = sanitized.replacingOccurrences(of: "{previousOutput}", with: "\\{previousOutput\\}")
        sanitized = sanitized.replacingOccurrences(of: "{stageName}", with: "\\{stageName\\}")
        return sanitized
    }

    private func interpolatePrompt(
        template: String,
        input: String,
        previousOutput: String,
        stageName: String
    ) -> String {
        let cleanInput = Self.sanitizeForPrompt(input)
        let cleanPrev = Self.sanitizeForPrompt(previousOutput)
        var result = template
        result = result.replacingOccurrences(of: "{input}", with: cleanInput)
        result = result.replacingOccurrences(of: "{previousOutput}", with: cleanPrev)
        result = result.replacingOccurrences(of: "{stageName}", with: stageName)
        return result
    }

    private func trackDelegation(
        from: BotProfile,
        to: BotProfile,
        stageId: String,
        action: String,
        message: String
    ) {
        let delegation = PlaybookDelegationEvent(
            id: UUID(),
            playbookId: playbook.id,
            stageId: stageId,
            fromBotId: from.id,
            fromBotName: from.name,
            toBotId: to.id,
            toBotName: to.name,
            action: action,
            message: message,
            status: .completed,
            resultSummary: "Handoff to \(to.name) for \(action)",
            timestamp: Date()
        )

        delegationEvents.append(delegation)

        // PROJECT M2 contract hook.
        delegationEventHandler?(delegation)

        emitTrace(
            operation: "peer_delegation",
            detail: "\(from.name) delegated to \(to.name) (\(action)): \(message)",
            metadata: [
                "playbookId": playbook.id.uuidString,
                "stageId": stageId,
                "fromBot": from.name,
                "toBot": to.name,
                "action": action
            ]
        )
    }

    // MARK: - Bot Turn Execution

    /// Runs one specialist turn.
    ///
    /// Live mode (`executionMode == .live`, set when a `BotManager` was injected
    /// and the host is not a test process): sends the prompt through the bot's
    /// real `BotSession` and returns the genuine model response.
    ///
    /// Simulated mode (tests, previews, or no `BotManager`): returns a clearly
    /// labeled placeholder that never claims real work was done. Live-mode
    /// failures surface as a ⚠️-marked turn result describing the error —
    /// the runner never substitutes fake success claims.
    private func runBotTurn(
        bot: BotProfile,
        roleId: String,
        stageId: String,
        stageName: String,
        prompt: String
    ) async -> String {
        if executionMode == .live, let manager = botManager {
            let session = manager.session(for: bot)
            return await Self.runLiveTurn(session: session, botName: bot.name, prompt: prompt)
        }
        return Self.generateSimulatedTurnResponse(
            botName: bot.name,
            roleId: roleId,
            stageId: stageId,
            stageName: stageName,
            prompt: prompt
        )
    }

    /// Sends a playbook turn through a real bot session with a hard timeout.
    /// Mirrors the timeout-race pattern in `MultiAgentDebateCoordinator`.
    ///
    /// - Returns: the model's genuine response text, or a `⚠️ Turn failed`
    ///   marker describing the failure (never a fabricated success claim).
    nonisolated static func runLiveTurn(session: BotSession, botName: String, prompt: String) async -> String {
        let cleanPrompt = SecretRedactor.redact(text: prompt)
        do {
            let response = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    // sendMessageAsync returns nil when the session is already
                    // generating; the empty check below turns that into an
                    // explicit failure marker (never a fake success).
                    let text = await session.sendMessageAsync(cleanPrompt) ?? ""
                    return SecretRedactor.redact(text: text)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.liveTurnTimeoutNanoseconds)
                    throw PlaybookExecutionError.stageExecutionFailed(
                        stageId: "",
                        reason: "Live turn for \(botName) exceeded 60s timeout"
                    )
                }
                guard let first = try await group.next() else {
                    throw PlaybookExecutionError.stageExecutionFailed(
                        stageId: "",
                        reason: "Live turn for \(botName) produced no response"
                    )
                }
                group.cancelAll()
                return first
            }
            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "⚠️ Turn failed for \(botName): live session returned an empty response."
            }
            return response
        } catch {
            return "⚠️ Turn failed for \(botName): \(error.localizedDescription)"
        }
    }

    /// Placeholder turn output for simulation mode (tests/previews).
    /// Explicitly labeled; makes no claims about builds, tests, or audits.
    nonisolated static func generateSimulatedTurnResponse(
        botName: String,
        roleId: String,
        stageId: String,
        stageName: String,
        prompt: String
    ) -> String {
        let promptPreview = String(SecretRedactor.redact(text: prompt).prefix(120))
        return """
        [SIMULATION — no agent session invoked]
        ### \(botName) — \(roleId)
        - **Stage**: \(stageName) (\(stageId))
        - **Prompt preview**: \(promptPreview)...
        - **Status**: simulated turn placeholder. In live execution this text would be the bot's real response via its BotSession.
        """
    }

    private func emitTrace(operation: String, detail: String, metadata: [String: String]? = nil) {
        TraceBus.shared.append(TraceEvent(
            source: "PlaybookRunner",
            operation: operation,
            detail: detail,
            metadata: metadata
        ))
    }
}
