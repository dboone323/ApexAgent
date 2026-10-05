import Foundation
import AppKit
import FoundationModels
import os

// MARK: - Provider Fallback Executor
//
// Bounded runtime fallback executor that traverses candidate providers,
// classifies errors, handles timeouts/empty responses, emits transition events,
// and guarantees graceful terminal states without silent swallowed failures.

@MainActor
public final class ProviderFallbackExecutor {
    public static let shared = ProviderFallbackExecutor()
    private static let logger = Logger(subsystem: "com.apexagent.ApexAgent", category: "ProviderFallback")

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
            let attemptStartedAt = ContinuousClock.now

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
                    Self.logger.info(
                        "Provider attempt succeeded: \(candidate.provider.displayName, privacy: .public) in \(self.elapsedMilliseconds(since: attemptStartedAt), format: .fixed(precision: 1)) ms"
                    )
                    let finalState = RuntimeTerminalState.completed(output: trimmed)
                    onEvent?(.completed(requestId: requestId, state: finalState))
                    return finalState
                } else {
                    let emptyErr = "\(candidate.provider.displayName) produced an empty response."
                    attemptedErrors.append(emptyErr)
                    Self.logger.warning(
                        "Provider attempt returned empty output: \(candidate.provider.displayName, privacy: .public) after \(self.elapsedMilliseconds(since: attemptStartedAt), format: .fixed(precision: 1)) ms"
                    )
                }
            } catch {
                let errorMsg = "\(candidate.provider.displayName) error: \(error.localizedDescription)"
                attemptedErrors.append(errorMsg)
                Self.logger.warning(
                    "Provider attempt failed: \(candidate.provider.displayName, privacy: .public) after \(self.elapsedMilliseconds(since: attemptStartedAt), format: .fixed(precision: 1)) ms"
                )
            }
        }

        let terminal = RuntimeTerminalState.fallbackExhausted(errors: attemptedErrors)
        onEvent?(.completed(requestId: requestId, state: terminal))
        return terminal
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return (Double(duration.seconds) + Double(duration.attoseconds) / 1e18) * 1_000
    }
}
