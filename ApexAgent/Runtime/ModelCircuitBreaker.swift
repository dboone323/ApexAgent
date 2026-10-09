import Foundation

// MARK: - Provider Fallback Strategy & Fault-Tolerant Circuit Breaker (Batch 62)

/// Lifecycle states of a model provider circuit breaker.
public enum CircuitBreakerState: Sendable, Equatable {
    case closed(failureCount: Int)
    case open(until: Date, lastError: String)
    case halfOpen

    public var isOpen: Bool {
        if case .open = self { return true }
        return false
    }

    public var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }

    public var isHalfOpen: Bool {
        if case .halfOpen = self { return true }
        return false
    }
}

/// Classification of errors to determine whether they should trip the provider circuit breaker.
public enum CircuitBreakerErrorCategory: String, Sendable, Equatable {
    case transient       // Network blips, 503, connection dropped
    case rateLimited     // 429 Too Many Requests
    case fatal           // Daemon not running, 401/403 auth rejected, connection refused
    case contextOverflow // Input prompt too long, model context exceeded (request-specific, non-tripping)

    public var tripsBreaker: Bool {
        self != .contextOverflow
    }
}

/// An autonomous fault-tolerant circuit breaker that isolates failing or degraded LLM providers.
public final class ModelCircuitBreaker: @unchecked Sendable {
    public static let shared = ModelCircuitBreaker()

    private let lock = NSLock()
    private var providerStates: [ModelProvider: CircuitBreakerState] = [:]
    private let failureThreshold: Int
    private let cooldownDuration: TimeInterval

    public init(failureThreshold: Int = 3, cooldownDuration: TimeInterval = 30.0) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldownDuration = max(1.0, cooldownDuration)
    }

    /// Evaluates whether a given provider can currently accept requests.
    public func canAttempt(provider: ModelProvider, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let state = providerStates[provider] ?? .closed(failureCount: 0)
        switch state {
        case .closed:
            return true
        case .open(let until, _):
            if now >= until {
                // Cooldown elapsed, allow a trial request
                providerStates[provider] = .halfOpen
                return true
            }
            return false
        case .halfOpen:
            return true
        }
    }

    /// Retrieves current state of a provider's circuit breaker.
    public func state(for provider: ModelProvider, now: Date = Date()) -> CircuitBreakerState {
        lock.lock()
        defer { lock.unlock() }

        let current = providerStates[provider] ?? .closed(failureCount: 0)
        if case .open(let until, _) = current, now >= until {
            return .halfOpen
        }
        return current
    }

    /// Records a successful invocation, restoring the circuit breaker to closed state.
    public func recordSuccess(for provider: ModelProvider) {
        lock.lock()
        defer { lock.unlock() }
        providerStates[provider] = .closed(failureCount: 0)
    }

    /// Classifies an error message into a circuit breaker error category.
    public static func classify(message: String) -> CircuitBreakerErrorCategory {
        let lower = message.lowercased()
        if lower.contains("context length")
            || lower.contains("maximum context")
            || lower.contains("token limit")
            || lower.contains("prompt is too long")
            || lower.contains("too many tokens") {
            return .contextOverflow
        }
        if lower.contains("rate limit")
            || lower.contains("429")
            || lower.contains("quota exceeded")
            || lower.contains("resource exhausted") {
            return .rateLimited
        }
        if lower.contains("connection refused")
            || lower.contains("daemon not running")
            || lower.contains("401")
            || lower.contains("403")
            || lower.contains("unauthorized")
            || lower.contains("forbidden") {
            return .fatal
        }
        return .transient
    }

    /// Records a failed invocation for the specified provider.
    public func recordFailure(
        for provider: ModelProvider,
        errorMessage: String,
        now: Date = Date()
    ) {
        let category = Self.classify(message: errorMessage)
        guard category.tripsBreaker else {
            // Context overflows do not indicate provider degradation
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let currentState = providerStates[provider] ?? .closed(failureCount: 0)
        switch currentState {
        case .closed(let failures):
            let newCount = failures + 1
            if newCount >= failureThreshold || category == .fatal {
                let openUntil = now.addingTimeInterval(cooldownDuration)
                providerStates[provider] = .open(until: openUntil, lastError: errorMessage)
            } else {
                providerStates[provider] = .closed(failureCount: newCount)
            }
        case .halfOpen:
            // Failed trial request immediately re-opens the breaker
            let openUntil = now.addingTimeInterval(cooldownDuration)
            providerStates[provider] = .open(until: openUntil, lastError: errorMessage)
        case .open:
            break
        }
    }

    /// Filters and prioritizes candidates, skipping those whose circuit breaker is open.
    /// If all candidates are open, returns all original candidates to avoid deadlocks.
    public func filterAvailableCandidates(
        candidates: [ProviderCandidate],
        now: Date = Date()
    ) -> [ProviderCandidate] {
        guard !candidates.isEmpty else { return [] }

        var available: [ProviderCandidate] = []
        for candidate in candidates {
            if canAttempt(provider: candidate.provider, now: now) {
                available.append(candidate)
            }
        }

        return available.isEmpty ? candidates : available
    }

    /// Resets state for a specific provider, or all providers if nil.
    public func reset(for provider: ModelProvider? = nil) {
        lock.lock()
        defer { lock.unlock() }

        if let provider = provider {
            providerStates.removeValue(forKey: provider)
        } else {
            providerStates.removeAll()
        }
    }
}
