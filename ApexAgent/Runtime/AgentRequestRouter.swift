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

        let effectiveInstructions = resolvedContext.effectiveInstructions
        let effectiveProvider = resolvedContext.effectiveProvider
        let effectiveToolCallingMode: AgentToolCallingMode = if request.toolCallingMode == .auto {
            IntentToolSelector.shouldEnableTools(
                for: request.prompt,
                hasAttachments: !request.attachments.isEmpty
            ) ? .auto : .disabled
        } else {
            request.toolCallingMode
        }

        let effectiveAllowedTools: [String]? = {
            switch resolvedContext.source {
            case .archetype, .botProfileOverride:
                let base = resolvedContext.effectiveAllowedTools.filter {
                    $0 != "delegate_task" && $0 != "convene_meeting" && $0 != "dispatch_swarm"
                }
                if !base.isEmpty {
                    return base
                } else if effectiveToolCallingMode == .disabled {
                    return []
                } else {
                    return IntentToolSelector.selectRelevantToolNames(
                        for: request.prompt,
                        allSchemas: getParsedSchemas()
                    )
                }
            case .globalDefault:
                if !resolvedContext.effectiveAllowedTools.isEmpty {
                    return resolvedContext.effectiveAllowedTools
                } else if effectiveToolCallingMode == .disabled {
                    return []
                } else {
                    return IntentToolSelector.selectRelevantToolNames(
                        for: request.prompt,
                        allSchemas: getParsedSchemas()
                    )
                }
            }
        }()

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
}
