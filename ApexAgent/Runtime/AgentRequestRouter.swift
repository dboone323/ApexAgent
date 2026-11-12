import Foundation
import AppKit
import FoundationModels

// MARK: - Canonical Agent Request Router
//
// Single request router and event dispatcher connecting all ingress points
// (GUI Bots, Legacy Chat, CLI, Gateway, Daemon, Routines, and App Intents)
// to candidate planning, tool governance, session task ownership, and lifecycle events.

@MainActor
public final class AgentRequestRouter {
    public static let shared = AgentRequestRouter()

    private var eventListeners: [(RuntimeEvent) -> Void] = []

    public init() {}

    // MARK: - Event Bus Subscription

    public func addEventListener(_ listener: @escaping (RuntimeEvent) -> Void) {
        eventListeners.append(listener)
    }

    public func broadcast(_ event: RuntimeEvent) {
        for listener in eventListeners {
            listener(event)
        }
    }

    // MARK: - Request Processing

    /// Dispatches an AgentRequest through candidate resolution, provider fallback, and tool governance.
    func route(
        _ request: AgentRequest,
        bot: BotProfile? = nil,
        session: LanguageModelSession? = nil,
        history: [ChatMessage] = [],
        instructions: String = "",
        orchestrator: AgentOrchestrator,
        onEvent: (@Sendable (RuntimeEvent) -> Void)? = nil,
        onUpdate: (@Sendable (String) -> Void)? = nil
    ) async -> RuntimeTerminalState {
        // 1. Broadcast turn start
        let turnEvent = RuntimeEvent.turnStarted(requestId: request.id, conversationId: request.conversationId)
        broadcast(turnEvent)
        onEvent?(turnEvent)

        // 2. Resolve precedence deterministically (BotProfile > Archetype > Global defaults)
        let archetypeName: String? = switch request.senderIdentity {
        case .archetype(let type): type.rawValue
        default: nil
        }
        let resolvedContext = AgentPrecedenceResolver.resolve(
            bot: bot,
            archetypeName: archetypeName,
            globalInstructions: instructions,
            globalProvider: ModelRegistry.activeProvider()
        )

        var baseInstructions = resolvedContext.effectiveInstructions
        let workspacePath = await MainActor.run { orchestrator.currentWorkspacePath }
        let skillContext = SkillCatalog.skillInstructions(for: request.prompt, workspacePath: workspacePath)
        if !skillContext.isEmpty && !baseInstructions.contains(skillContext) {
            baseInstructions += "\n\n" + skillContext
        }

        let memoryTiers = await MainActor.run {
            let activeSpace = SpaceManager.shared.activeSpace
            return SpaceMemoryTierManager.shared.buildComposedMemoryInstructions(space: activeSpace, workspacePath: workspacePath)
        }
        if !memoryTiers.isEmpty {
            let sections = memoryTiers.components(separatedBy: "\n\n===")
            for section in sections {
                let firstLine = section.components(separatedBy: "\n").first ?? ""
                let header = section.hasPrefix("===") ? firstLine : "===" + firstLine
                if !header.isEmpty && !baseInstructions.contains(header) {
                    let block = section.hasPrefix("===") ? section : "===" + section
                    baseInstructions += "\n\n" + block
                }
            }
        }

        let verifiedInstructions = AgentExecutionVerification.applyingDirective(
            to: baseInstructions
        )
        let effectiveInstructions = Self.applyingDirectAddressPolicy(
            base: verifiedInstructions,
            isDirectMention: request.isDirectMention
        )
        let effectiveProvider = resolvedContext.effectiveProvider
        // Intent gating MUST run against the originating user utterance, not the
        // model-facing prompt. Spaces/group chat pass a synthesized transcript
        // scaffold whose boilerplate ("delegate", "meeting", teammate @handles)
        // would otherwise read as tool intent on every single turn and inject the
        // coordination pack regardless of what the human actually asked.
        let effectiveToolCallingMode: AgentToolCallingMode = if request.toolCallingMode == .auto {
            IntentToolSelector.shouldEnableTools(
                for: request.intentText,
                hasAttachments: !request.attachments.isEmpty
            ) ? .auto : .disabled
        } else {
            request.toolCallingMode
        }

        let effectiveAllowedTools: [String]? = Self.resolveEffectiveAllowedTools(
            resolvedContext: resolvedContext,
            toolCallingMode: effectiveToolCallingMode,
            intentText: request.intentText,
            isDirectMention: request.isDirectMention
        )

        // 3. Build candidate chain
        let candidates = ModelRegistry.buildCandidateChain(
            preferred: effectiveProvider,
            bot: bot,
            prompt: request.prompt,
            history: history,
            instructions: effectiveInstructions,
            tools: effectiveAllowedTools ?? [],
            hasAttachments: !request.attachments.isEmpty
        )

        // 4. Execute with bounded fallback
        let terminalState = await ProviderFallbackExecutor.shared.execute(
            candidates: candidates,
            prompt: request.prompt,
            attachments: request.attachments,
            history: history,
            instructions: effectiveInstructions,
            toolCallingMode: effectiveToolCallingMode,
            bot: bot,
            session: session,
            allowedTools: effectiveAllowedTools,
            orchestrator: orchestrator,
            requestId: request.id,
            onEvent: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.broadcast(event)
                }
                onEvent?(event)
            },
            onUpdate: onUpdate
        )

        // 4. Broadcast terminal event
        let completionEvent = RuntimeEvent.completed(requestId: request.id, state: terminalState)
        broadcast(completionEvent)
        onEvent?(completionEvent)

        // 5. Cleanup session lifecycle
        SessionLifecycleManager.shared.unregister(sessionId: request.conversationId)

        return terminalState
    }

    // MARK: - Direct-Address Policy (extracted for unit testing)

    /// Appends the direct-address directive when a human explicitly @mentioned
    /// the agent. Idempotent so repeated routing cannot stack the directive.
    static func applyingDirectAddressPolicy(base: String, isDirectMention: Bool) -> String {
        guard isDirectMention else { return base }
        if base.contains(AgentRequest.directAddressDirective) { return base }
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return AgentRequest.directAddressDirective }
        return trimmed + "\n\n" + AgentRequest.directAddressDirective
    }

    /// Resolves the final tool allowlist for a turn.
    ///
    /// Two invariants this function owns:
    /// 1. Gating/selection is computed from `intentText` (the human utterance),
    ///    never the model-facing transcript scaffold.
    /// 2. On a direct @mention, every delegation tool is withheld regardless of
    ///    how it entered the list — otherwise the agent responds with
    ///    "I'll have <teammate> handle that" instead of doing the work.
    static func resolveEffectiveAllowedTools(
        resolvedContext: ResolvedAgentContext,
        toolCallingMode: AgentToolCallingMode,
        intentText: String,
        isDirectMention: Bool
    ) -> [String]? {
        var base: [String]

        switch resolvedContext.source {
        case .archetype, .botProfileOverride:
            let configured = resolvedContext.effectiveAllowedTools.filter {
                !AgentRuntimeCoordination.delegationTools.contains($0)
            }
            if configured.isEmpty {
                guard toolCallingMode != .disabled else { return [] }
                base = IntentToolSelector.selectRelevantToolNames(
                    for: intentText,
                    allSchemas: getParsedSchemas()
                )
            } else {
                base = configured
            }

        case .globalDefault:
            guard !resolvedContext.effectiveAllowedTools.isEmpty else {
                guard toolCallingMode != .disabled else { return [] }
                base = IntentToolSelector.selectRelevantToolNames(
                    for: intentText,
                    allSchemas: getParsedSchemas()
                )
                break
            }
            base = resolvedContext.effectiveAllowedTools
        }

        guard isDirectMention else { return base }
        return base.filter { !AgentRuntimeCoordination.delegationTools.contains($0) }
    }
}
