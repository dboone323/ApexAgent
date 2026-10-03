import Foundation
import AppKit
import FoundationModels

// MARK: - Provider Fallback Executor
//
// Bounded runtime fallback executor that traverses candidate providers,
// classifies errors, handles timeouts/empty responses, emits transition events,
// and guarantees graceful terminal states without silent swallowed failures.

@MainActor
public final class ProviderFallbackExecutor {
    public static let shared = ProviderFallbackExecutor()

    public init() {}

    /// Executes a request across an ordered chain of provider candidates with bounded fallback.
    func execute(
        candidates: [ProviderCandidate],
        prompt: String,
        attachments: [NSImage] = [],
        history: [ChatMessage] = [],
        instructions: String = "",
        toolCallingMode: AgentToolCallingMode = .auto,
        bot: BotProfile? = nil,
        session: LanguageModelSession? = nil,
        allowedTools: [String]? = nil,
        orchestrator: AgentOrchestrator,
        requestId: UUID = UUID(),
        onEvent: (@Sendable (RuntimeEvent) -> Void)? = nil,
        onUpdate: (@Sendable (String) -> Void)? = nil
    ) async -> RuntimeTerminalState {
        guard !candidates.isEmpty else {
            return .fallbackExhausted(errors: ["No provider candidates available"])
        }

        var attemptedErrors: [String] = []
        var previousProvider: ModelProvider?

        for (index, candidate) in candidates.enumerated() {
            // Check cancellation before each attempt
            if Task.isCancelled {
                return .cancelled(reason: "Task was cancelled before invoking \(candidate.provider.displayName)")
            }

            if let prev = previousProvider {
                let lastErr = attemptedErrors.last ?? "Unknown error"
                onEvent?(.providerFallback(from: prev, to: candidate.provider, error: lastErr))
            } else {
                onEvent?(.providerSelected(provider: candidate.provider, reason: candidate.reason))
            }
            previousProvider = candidate.provider

            var accumulatedText = ""

            let engine = ModelRegistry.engine(
                for: candidate.provider,
                bot: bot,
                session: session,
                allowedTools: allowedTools ?? [],
                orchestrator: orchestrator
            )

            do {
                try await engine.streamResponse(
                    prompt: prompt,
                    attachments: attachments,
                    history: history,
                    instructions: instructions,
                    toolCallingMode: toolCallingMode,
                    onUpdate: { partial in
                        accumulatedText = partial
                        if !partial.hasPrefix("⚠️ The on-device model returned no output") || index == candidates.count - 1 {
                            onUpdate?(partial)
                            onEvent?(.streamingDelta(requestId: requestId, delta: partial))
                        }
                    }
                )

                let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("⚠️ The on-device model returned no output") {
                    let finalState = RuntimeTerminalState.completed(output: trimmed)
                    onEvent?(.completed(requestId: requestId, state: finalState))
                    return finalState
                } else {
                    let emptyErr = "\(candidate.provider.displayName) produced an empty response."
                    attemptedErrors.append(emptyErr)
                }
            } catch {
                let errorMsg = "\(candidate.provider.displayName) error: \(error.localizedDescription)"
                attemptedErrors.append(errorMsg)
            }
        }

        let terminal = RuntimeTerminalState.fallbackExhausted(errors: attemptedErrors)
        onEvent?(.completed(requestId: requestId, state: terminal))
        return terminal
    }
}
