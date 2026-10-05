import Foundation
import AppKit

// MARK: - Canonical Agent Runtime Contract
//
// Governs request lifecycle, agent identities, streamable events, error classifications,
// and terminal states across all ingress surfaces (GUI Bots, Legacy Orchestrator, CLI,
// Gateway, Daemon, Routines, and App Intents).

/// Represents the identity of the agent or ingress point executing a request.
public enum AgentIdentity: Equatable, Hashable, Sendable {
    case bot(id: UUID, name: String)
    case archetype(AgentType)
    case orchestrator
    case cli
    case gateway(connectionId: UUID)
    case intent(name: String)
    case routine(name: String)
    case custom(String)

    public var displayName: String {
        switch self {
        case .bot(_, let name):
            return name
        case .archetype(let type):
            return type.displayName
        case .orchestrator:
            return "Apex Prime"
        case .cli:
            return "CLI"
        case .gateway(let id):
            return "Gateway (\(id.uuidString.prefix(6)))"
        case .intent(let name):
            return "Intent (\(name))"
        case .routine(let name):
            return "Routine (\(name))"
        case .custom(let name):
            return name
        }
    }

    public var rawIdentifier: String {
        switch self {
        case .bot(let id, _):
            return "bot:\(id.uuidString)"
        case .archetype(let type):
            return "archetype:\(type.rawValue)"
        case .orchestrator:
            return "orchestrator:prime"
        case .cli:
            return "cli:local"
        case .gateway(let id):
            return "gateway:\(id.uuidString)"
        case .intent(let name):
            return "intent:\(name)"
        case .routine(let name):
            return "routine:\(name)"
        case .custom(let name):
            return "custom:\(name)"
        }
    }
}

/// Strongly typed terminal states for an agent execution turn.
public enum RuntimeTerminalState: Equatable, Sendable {
    case completed(output: String)
    case failed(error: String, isRetryable: Bool)
    case cancelled(reason: String)
    case timedOut(duration: TimeInterval)
    case emptyOutput
    case fallbackExhausted(errors: [String])

    public var isSuccess: Bool {
        if case .completed = self { return true }
        return false
    }

    public var outputContent: String? {
        if case .completed(let out) = self { return out }
        return nil
    }

    public var terminalDescription: String {
        switch self {
        case .completed:
            return "Completed"
        case .failed(let err, _):
            return "Failed: \(err)"
        case .cancelled(let reason):
            return "Cancelled: \(reason)"
        case .timedOut(let sec):
            return "Timed out after \(sec)s"
        case .emptyOutput:
            return "Empty response from provider"
        case .fallbackExhausted(let errs):
            return "Fallback exhausted: \(errs.joined(separator: "; "))"
        }
    }

    /// Stable user-facing text shared by UI, intents, CLI, and gateway adapters.
    public var userFacingMessage: String {
        switch self {
        case .completed(let output):
            return output.isEmpty ? "The task completed without a response." : output
        case .failed(let error, let isRetryable):
            return isRetryable
                ? "The request failed: \(error) You can retry or choose another provider."
                : "The request could not be completed: \(error)"
        case .cancelled(let reason):
            return "Generation cancelled: \(reason)"
        case .timedOut(let duration):
            return "The request timed out after \(Int(duration)) seconds. Try again or choose another provider."
        case .emptyOutput:
            return "The provider returned no response. Try again or choose another provider."
        case .fallbackExhausted(let errors):
            let detail = errors.isEmpty ? "No provider details were available." : errors.joined(separator: "; ")
            return "All available providers failed. Try again or review provider settings. Details: \(detail)"
        }
    }
}

/// A streamable event representing granular progress during an agent turn.
public enum RuntimeEvent: Sendable {
    case turnStarted(requestId: UUID, conversationId: UUID)
    case providerSelected(provider: ModelProvider, reason: String?)
    case providerFallback(from: ModelProvider, to: ModelProvider, error: String)
    case streamingDelta(requestId: UUID, delta: String)
    case toolCallStarted(id: String, tool: String, args: String)
    case toolCallCompleted(id: String, tool: String, result: String)
    case toolCallFailed(id: String, tool: String, error: String)
    case confirmationRequired(id: UUID, tool: String, risk: String)
    case completed(requestId: UUID, state: RuntimeTerminalState)
}

/// Represents a prioritized candidate provider in the fallback chain.
public struct ProviderCandidate: Sendable {
    public let provider: ModelProvider
    public let modelName: String?
    public let preferenceReason: String
    public var reason: String? { preferenceReason }
    public let priority: Int

    public init(provider: ModelProvider, modelName: String? = nil, reason: String? = nil, priority: Int = 0) {
        self.provider = provider
        self.modelName = modelName
        self.preferenceReason = reason ?? "Default"
        self.priority = priority
    }
}

/// Tools that hand work to *another* agent. When a bot is explicitly
/// @mentioned by a human it owns the turn, so these are withheld — otherwise
/// the model delegates the task back instead of doing it (see
/// `AgentRequestRouter.resolveEffectiveAllowedTools`).
public enum AgentRuntimeCoordination {
    public static let delegationTools: Set<String> = [
        "delegate_task", "convene_meeting", "dispatch_swarm", "ask_bot"
    ]
}

/// Shared contract for reporting state-changing agent actions.
public enum AgentExecutionVerification {
    public static let directive = """
    === EXECUTION VERIFICATION ===
    A command proposal, code snippet, user approval, or successful process exit is not proof that the requested outcome occurred. For action requests, use an available tool to perform the work; after a successful state-changing action, use a separate read-only check of the exact requested end state before claiming completion. Do not rerun a mutating action just to verify it. A read-only check does not need another verification pass. If no suitable action or verification tool is available, or the check does not confirm the outcome, say clearly that the work was not completed or remains unverified. Never invent tool names, APIs, or results.
    """

    public static func applyingDirective(to instructions: String) -> String {
        guard !instructions.contains(directive) else { return instructions }
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directive }
        return trimmed + "\n\n" + directive
    }

    public static func applyingToolResultGuidance(toolName: String, result: String) -> String {
        guard toolName == "run_shell_command", !result.hasPrefix("ERROR:") else { return result }
        return result + """


        [POST-EXECUTION CHECK REQUIRED: If this command performed the requested state change or action, inspect the exact resulting state with a separate read-only tool before reporting success. Do not treat approval, command output, or exit status alone as proof.]
        """
    }
}

/// Canonical request model dispatched to the AgentRequestRouter.
public struct AgentRequest: Sendable {
    public let id: UUID
    public let conversationId: UUID
    public let senderIdentity: AgentIdentity
    /// The full text handed to the model. May be a synthesized transcript
    /// scaffold (Spaces, group chat) rather than the raw user utterance.
    public let prompt: String
    /// The raw user utterance used for *intent gating only* — tool on/off
    /// selection. Defaults to `prompt`. Callers that build a transcript must
    /// set this to the originating message so the scaffold's own vocabulary
    /// ("delegate", "meeting", teammate names) cannot fake tool intent.
    public let intentText: String
    /// True when a human explicitly @mentioned this agent's handle, making it
    /// directly responsible for the turn. Suppresses delegation tools and
    /// injects a direct-address directive.
    public let isDirectMention: Bool
    public let attachments: [NSImage]
    public let toolCallingMode: AgentToolCallingMode
    public let contextBudget: Int?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        conversationId: UUID = UUID(),
        senderIdentity: AgentIdentity = .orchestrator,
        prompt: String,
        intentText: String? = nil,
        isDirectMention: Bool = false,
        attachments: [NSImage] = [],
        toolCallingMode: AgentToolCallingMode = .auto,
        contextBudget: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.conversationId = conversationId
        self.senderIdentity = senderIdentity
        self.prompt = prompt
        self.intentText = intentText ?? prompt
        self.isDirectMention = isDirectMention
        self.attachments = attachments
        self.toolCallingMode = toolCallingMode
        self.contextBudget = contextBudget
        self.metadata = metadata
    }

    /// Appended to system instructions when `isDirectMention` is set so the
    /// agent executes rather than routing the task to a teammate.
    public static let directAddressDirective = """
    === DIRECT ADDRESS ===
    A human explicitly @mentioned you, so this turn is yours. Answer it yourself \
    using your own tools and reasoning. Do NOT hand the task back to the user, and do NOT \
    delegate, defer, or tag another agent — delegation tools are withheld for this turn. \
    If the request needs no action, simply answer. Otherwise, do the work and report \
    the concrete result.
    """
}

/// Classification of runtime errors to determine fallback eligibility and retry strategy.
public enum RuntimeErrorClassification: Equatable, Sendable {
    case retryable(delay: TimeInterval)
    case fallbackEligible(reason: String)
    case permissionDenied(reason: String)
    case malformedToolCall(tool: String, details: String)
    case cancelled
    case terminal(reason: String)

    public var isRetryable: Bool {
        switch self {
        case .retryable, .fallbackEligible:
            return true
        case .permissionDenied, .malformedToolCall, .cancelled, .terminal:
            return false
        }
    }
}

public enum RuntimeErrorClassifier {
    public static func classify(error: any Error) -> RuntimeErrorClassification {
        if error is CancellationError {
            return .cancelled
        }

        let nsError = error as NSError
        let domain = nsError.domain
        let code = nsError.code
        let description = error.localizedDescription.lowercased()

        // Cancellation checks
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled {
            return .cancelled
        }
        if description.contains("cancelled") || description.contains("canceled") {
            return .cancelled
        }

        // Permission / Authorization
        if domain == "AgentSecurity" || code == 403 || description.contains("permission denied") || description.contains("unauthorized") {
            return .permissionDenied(reason: error.localizedDescription)
        }

        // Context / token limits -> Fallback eligible
        if description.contains("context length") ||
            description.contains("token limit") ||
            description.contains("maximum context") ||
            description.contains("prompt exceeds") ||
            description.contains("overflow") {
            return .fallbackEligible(reason: "Context limit exceeded: \(error.localizedDescription)")
        }

        // Rate limit / Quota / 429 -> Fallback eligible
        if code == 429 || description.contains("resource_exhausted") || description.contains("quota exceeded") || description.contains("rate limit") {
            return .fallbackEligible(reason: "Quota / Rate limit reached: \(error.localizedDescription)")
        }

        // Unreachable local server / Connection refused (Ollama or MLX down) -> Fallback eligible
        if (domain == NSURLErrorDomain && (code == NSURLErrorCannotConnectToHost || code == NSURLErrorTimedOut)) ||
            description.contains("connection refused") ||
            description.contains("could not connect") {
            return .fallbackEligible(reason: "Provider unreachable: \(error.localizedDescription)")
        }

        // Server errors 500, 502, 503, 504 -> Fallback eligible
        if code >= 500 && code < 600 {
            return .fallbackEligible(reason: "Provider server error (\(code)): \(error.localizedDescription)")
        }

        // Malformed tool calls
        if description.contains("tool call") && (description.contains("invalid json") || description.contains("decode error")) {
            return .malformedToolCall(tool: "unknown", details: error.localizedDescription)
        }

        return .terminal(reason: error.localizedDescription)
    }
}
