// ModelTieringCascade.swift
// Batch 125: Dynamic model fallback cascade across Copilot, Gemini, Ollama,
// and Apple On-Device with provider health tracking and failover resolution.

import Foundation
import FoundationModels

public enum ProviderHealthStatus: String, Sendable, Codable, Equatable {
    case healthy
    case rateLimited
    case degraded
    case offline
}

public struct ProviderHealth: Sendable, Equatable, Codable {
    public let provider: ModelProvider
    public var status: ProviderHealthStatus
    public var consecutiveFailures: Int
    public var rateLimitUntil: Date?
    public var lastChecked: Date
    public var isAvailable: Bool { status == .healthy || status == .degraded }

    public init(
        provider: ModelProvider,
        status: ProviderHealthStatus = .healthy,
        consecutiveFailures: Int = 0,
        rateLimitUntil: Date? = nil,
        lastChecked: Date = Date()
    ) {
        self.provider = provider
        self.status = status
        self.consecutiveFailures = consecutiveFailures
        self.rateLimitUntil = rateLimitUntil
        self.lastChecked = lastChecked
    }
}

public actor ModelTieringCascade {
    public static let shared = ModelTieringCascade()

    private var healthMap: [ModelProvider: ProviderHealth] = [:]

    public static let defaultCascadeLadder: [ModelProvider] = [
        .gitHubCopilot,
        .cloudGemini,
        .localOllama,
        .appleOnDevice
    ]

    public func getHealth(for provider: ModelProvider) -> ProviderHealth {
        if var health = healthMap[provider] {
            if health.status == .rateLimited, let until = health.rateLimitUntil, until <= Date() {
                health.status = .healthy
                health.rateLimitUntil = nil
                healthMap[provider] = health
            }
            return health
        }
        return ProviderHealth(
            provider: provider,
            status: .healthy,
            consecutiveFailures: 0,
            rateLimitUntil: nil,
            lastChecked: Date()
        )
    }

    public func recordSuccess(for provider: ModelProvider) {
        let health = ProviderHealth(
            provider: provider,
            status: .healthy,
            consecutiveFailures: 0,
            rateLimitUntil: nil,
            lastChecked: Date()
        )
        healthMap[provider] = health
    }

    public func recordFailure(
        for provider: ModelProvider,
        isRateLimit: Bool = false,
        rateLimitDuration: TimeInterval = 60
    ) {
        var current = getHealth(for: provider)
        current.consecutiveFailures += 1
        current.lastChecked = Date()

        if isRateLimit {
            current.status = .rateLimited
            current.rateLimitUntil = Date().addingTimeInterval(rateLimitDuration)
        } else if current.consecutiveFailures >= 3 {
            current.status = .offline
            current.rateLimitUntil = nil
        } else {
            current.status = .degraded
            current.rateLimitUntil = nil
        }
        healthMap[provider] = current
    }

    public func resolveActiveProvider(
        requested: ModelProvider? = nil,
        ladder: [ModelProvider] = ModelTieringCascade.defaultCascadeLadder,
        isLocalOllamaRunning: Bool = true,
        hasGeminiKey: Bool = true,
        hasCopilotAuth: Bool = true
    ) -> (provider: ModelProvider, reason: String) {
        if let requested = requested {
            let health = getHealth(for: requested)
            let meetsAuth = meetsPrerequisites(
                for: requested,
                isLocalOllamaRunning: isLocalOllamaRunning,
                hasGeminiKey: hasGeminiKey,
                hasCopilotAuth: hasCopilotAuth
            )
            if health.isAvailable && meetsAuth {
                return (requested, "Requested provider is healthy")
            }
        }

        for candidate in ladder {
            guard meetsPrerequisites(
                for: candidate,
                isLocalOllamaRunning: isLocalOllamaRunning,
                hasGeminiKey: hasGeminiKey,
                hasCopilotAuth: hasCopilotAuth
            ) else {
                continue
            }

            let health = getHealth(for: candidate)
            guard health.isAvailable else {
                continue
            }

            let reason: String
            if candidate == .appleOnDevice {
                reason = "All higher tier engines unavailable; defaulted to on-device AFM"
            } else if requested != nil {
                reason = "Failover to \(candidate.displayName) (requested provider unavailable)"
            } else {
                reason = "Cascade ladder selected \(candidate.displayName)"
            }
            return (candidate, reason)
        }

        return (.appleOnDevice, "All higher tier engines unavailable; defaulted to on-device AFM")
    }

    private func meetsPrerequisites(
        for provider: ModelProvider,
        isLocalOllamaRunning: Bool,
        hasGeminiKey: Bool,
        hasCopilotAuth: Bool
    ) -> Bool {
        switch provider {
        case .gitHubCopilot:
            return hasCopilotAuth
        case .cloudGemini:
            return hasGeminiKey
        case .localOllama:
            return isLocalOllamaRunning
        case .appleOnDevice:
            return true
        default:
            return true
        }
    }

    public func resetAll() {
        healthMap.removeAll()
    }
}
