import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 62 — Provider Fallback Strategy & Fault-Tolerant Circuit Breaker Tests")
struct ModelCircuitBreakerTests {

    @Test("Initial state is closed and can accept attempts")
    func initialStateIsClosed() {
        let breaker = ModelCircuitBreaker(failureThreshold: 3, cooldownDuration: 10.0)
        breaker.reset()

        #expect(breaker.canAttempt(provider: .localOllama))
        let state = breaker.state(for: .localOllama)
        #expect(state.isClosed)
        if case .closed(let count) = state {
            #expect(count == 0)
        }
    }

    @Test("Repeated transient errors trip breaker into open state")
    func repeatedTransientErrorsTripBreaker() {
        let breaker = ModelCircuitBreaker(failureThreshold: 3, cooldownDuration: 15.0)
        let now = Date()

        breaker.recordFailure(for: .cloudGemini, errorMessage: "HTTP 503 Service Unavailable", now: now)
        #expect(breaker.canAttempt(provider: .cloudGemini, now: now))
        #expect(breaker.state(for: .cloudGemini, now: now) == .closed(failureCount: 1))

        breaker.recordFailure(for: .cloudGemini, errorMessage: "Network connection dropped", now: now)
        #expect(breaker.canAttempt(provider: .cloudGemini, now: now))
        #expect(breaker.state(for: .cloudGemini, now: now) == .closed(failureCount: 2))

        breaker.recordFailure(for: .cloudGemini, errorMessage: "HTTP 504 Gateway Timeout", now: now)
        #expect(!breaker.canAttempt(provider: .cloudGemini, now: now))
        let state = breaker.state(for: .cloudGemini, now: now)
        #expect(state.isOpen)
    }

    @Test("Fatal authentication or connection refused error immediately trips circuit breaker")
    func fatalErrorImmediatelyTripsBreaker() {
        let breaker = ModelCircuitBreaker(failureThreshold: 3, cooldownDuration: 20.0)
        let now = Date()

        breaker.recordFailure(for: .localMLX, errorMessage: "Connection refused to daemon at port 8000", now: now)
        #expect(!breaker.canAttempt(provider: .localMLX, now: now))
        #expect(breaker.state(for: .localMLX, now: now).isOpen)
    }

    @Test("Context length overflow error does not increment failure count or trip breaker")
    func contextOverflowDoesNotTripBreaker() {
        let breaker = ModelCircuitBreaker(failureThreshold: 2, cooldownDuration: 10.0)
        let now = Date()

        breaker.recordFailure(for: .appleOnDevice, errorMessage: "Prompt is too long: token limit exceeded 4096 tokens", now: now)
        #expect(breaker.canAttempt(provider: .appleOnDevice, now: now))
        #expect(breaker.state(for: .appleOnDevice, now: now) == .closed(failureCount: 0))
    }

    @Test("Breaker transitions to halfOpen after cooldown and resets to closed on success")
    func cooldownTransitionsToHalfOpenAndResets() {
        let cooldown: TimeInterval = 10.0
        let breaker = ModelCircuitBreaker(failureThreshold: 1, cooldownDuration: cooldown)
        let t0 = Date()

        breaker.recordFailure(for: .localOllama, errorMessage: "Daemon not running", now: t0)
        #expect(!breaker.canAttempt(provider: .localOllama, now: t0))

        // Advance time past cooldown
        let t1 = t0.addingTimeInterval(cooldown + 1.0)
        #expect(breaker.canAttempt(provider: .localOllama, now: t1))
        #expect(breaker.state(for: .localOllama, now: t1).isHalfOpen)

        // Successful invocation resets to closed
        breaker.recordSuccess(for: .localOllama)
        #expect(breaker.state(for: .localOllama, now: t1) == .closed(failureCount: 0))
    }

    @Test("Failure in halfOpen immediately re-opens the circuit breaker")
    func halfOpenFailureReopensBreaker() {
        let cooldown: TimeInterval = 10.0
        let breaker = ModelCircuitBreaker(failureThreshold: 1, cooldownDuration: cooldown)
        let t0 = Date()

        breaker.recordFailure(for: .cloudGemini, errorMessage: "Daemon not running", now: t0)
        let t1 = t0.addingTimeInterval(cooldown + 1.0)
        _ = breaker.canAttempt(provider: .cloudGemini, now: t1) // triggers halfOpen

        // Trial fails
        breaker.recordFailure(for: .cloudGemini, errorMessage: "HTTP 500 Internal Error", now: t1)
        #expect(!breaker.canAttempt(provider: .cloudGemini, now: t1))
        #expect(breaker.state(for: .cloudGemini, now: t1).isOpen)
    }

    @Test("filterAvailableCandidates filters out open providers while preserving closed providers")
    func filterCandidatesSkipsOpenProviders() {
        let breaker = ModelCircuitBreaker(failureThreshold: 1, cooldownDuration: 60.0)
        let now = Date()

        breaker.recordFailure(for: .localOllama, errorMessage: "Connection refused", now: now)

        let candidates = [
            ProviderCandidate(provider: .localOllama, reason: "Local Ollama primary"),
            ProviderCandidate(provider: .cloudGemini, reason: "Cloud fallback")
        ]

        let filtered = breaker.filterAvailableCandidates(candidates: candidates, now: now)
        #expect(filtered.count == 1)
        #expect(filtered.first?.provider == .cloudGemini)

        // If all providers are open, fallback to all to prevent deadlock
        breaker.recordFailure(for: .cloudGemini, errorMessage: "Connection refused", now: now)
        let deadlocked = breaker.filterAvailableCandidates(candidates: candidates, now: now)
        #expect(deadlocked.count == 2)
    }
}
