import Foundation
import AppKit

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
                        onUpdate?(partial)
                        onEvent?(.streamingDelta(requestId: requestId, delta: partial))
                    }
                )

                let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    let emptyMsg = "Provider \(candidate.provider.displayName) returned empty output."
                    attemptedErrors.append("[\(candidate.provider.rawValue)] \(emptyMsg)")
                    if index < candidates.count - 1 {
                        continue // Fallback to next candidate
                    } else {
                        return .emptyOutput
                    }
                }

                return .completed(output: accumulatedText)
            } catch {
                let classification = RuntimeErrorClassifier.classify(error: error)
                switch classification {
                case .cancelled:
                    return .cancelled(reason: error.localizedDescription)
                case .permissionDenied(let reason):
                    return .failed(error: reason, isRetryable: false)
                case .fallbackEligible(let reason), .terminal(let reason):
                    attemptedErrors.append("[\(candidate.provider.rawValue)] \(reason)")
                    if index < candidates.count - 1 {
                        continue // Fallback to next candidate
                    }
                case .retryable(let delay):
                    attemptedErrors.append("[\(candidate.provider.rawValue)] Retryable delay \(delay)s: \(error.localizedDescription)")
                    if index < candidates.count - 1 {
                        continue
                    }
                case .malformedToolCall(let tool, let details):
                    attemptedErrors.append("[\(candidate.provider.rawValue)] Malformed tool '\(tool)': \(details)")
                    if index < candidates.count - 1 {
                        continue
                    }
                }
            }
        }

        return .fallbackExhausted(errors: attemptedErrors)
    }
}
