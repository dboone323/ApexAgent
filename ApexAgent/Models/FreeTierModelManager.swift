import Foundation
import SwiftUI
import os

// MARK: - Free-Tier Model Provider Option (Issue #118, J5)

/// Encapsulates the honest cost, privacy, and speed facts for a free-tier or on-device model provider.
public struct FreeTierModelOption: Identifiable, Sendable, Equatable {
    public var id: ModelProvider { provider }
    public let provider: ModelProvider
    public let displayName: String
    public let costFact: String
    public let privacyFact: String
    public let speedFact: String
    public let recommendedWorkload: String
    public let isDefault: Bool
    public let isPaid: Bool
    public let iconName: String

    public init(
        provider: ModelProvider,
        displayName: String,
        costFact: String,
        privacyFact: String,
        speedFact: String,
        recommendedWorkload: String,
        isDefault: Bool = false,
        isPaid: Bool = false,
        iconName: String = "cpu"
    ) {
        self.provider = provider
        self.displayName = displayName
        self.costFact = costFact
        self.privacyFact = privacyFact
        self.speedFact = speedFact
        self.recommendedWorkload = recommendedWorkload
        self.isDefault = isDefault
        self.isPaid = isPaid
        self.iconName = iconName
    }
}

// MARK: - Provider Availability Status

public enum ProviderAvailabilityStatus: Sendable, Equatable {
    case available
    case withdrawn(reason: String)
    case unavailable(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var isWithdrawn: Bool {
        if case .withdrawn = self { return true }
        return false
    }

    public var explanation: String? {
        switch self {
        case .available:
            return nil
        case .withdrawn(let reason):
            return reason
        case .unavailable(let reason):
            return reason
        }
    }
}

// MARK: - Free Tier Model Manager

/// Single source of truth for free-tier model availability, cost/privacy/speed explanations,
/// and graceful degradation when a free tier is withdrawn (the Gemini CLI lesson).
///
/// Guaranteed invariants:
/// 1. Never pushes a paid model.
/// 2. Never offers usage-based billing or "Add Credits".
/// 3. Never presents a withdrawn free tier as available.
/// 4. Gracefully degrades to local silicon if an external free tier is withdrawn.
public final class FreeTierModelManager: @unchecked Sendable {
    public static let shared = FreeTierModelManager()

    public static let withdrawnDefaultsKey = "apex.freeTier.withdrawnProviders"
    private static let logger = Logger(subsystem: "com.apexagent.ApexAgent", category: "FreeTierManager")

    private let lock = NSLock()
    private var inMemoryWithdrawals: [ModelProvider: String] = [:]

    public init() {
        loadWithdrawals()
    }

    // MARK: - Catalog of Free-Tier Options

    public func allOptions() -> [FreeTierModelOption] {
        [
            FreeTierModelOption(
                provider: .autoPicker,
                displayName: "Auto (Balanced Free Tier)",
                costFact: "Free ($0/mo) — Zero API costs; routes to local silicon first, zero billing required.",
                privacyFact: "Strictly On-Device First — 0 bytes leave your Mac for on-device context turns.",
                speedFact: "Adaptive — Sub-second response on-device; dynamically uses local engines.",
                recommendedWorkload: "General everyday coding, multi-agent debates, and autonomous plans.",
                isDefault: true,
                isPaid: false,
                iconName: "wand.and.stars"
            ),
            FreeTierModelOption(
                provider: .appleOnDevice,
                displayName: "Apple Intelligence (AFM 3 On-Device)",
                costFact: "Free ($0/mo) — 100% on-device execution powered directly by Apple Silicon.",
                privacyFact: "Strictly On-Device — 0 bytes leave your device. Zero cloud logging or inspection.",
                speedFact: "Instant (~30–60 tps) — Zero network round-trip latency, deterministic throughput.",
                recommendedWorkload: "High-privacy tasks, offline coding, and low-latency agent loops.",
                isDefault: false,
                isPaid: false,
                iconName: "apple.logo"
            ),
            FreeTierModelOption(
                provider: .localOllama,
                displayName: "Local Ollama (Llama 3 / Qwen / Gemma)",
                costFact: "Free ($0/mo) — Open-weights models run locally without commercial subscriptions.",
                privacyFact: "Local Only — Bound to localhost:11434; zero telemetry leaves your machine.",
                speedFact: "Fast — Dependent on local unified memory and Metal GPU bandwidth.",
                recommendedWorkload: "Large-context coding (up to 32k tokens), specialized system architecture.",
                isDefault: false,
                isPaid: false,
                iconName: "server.rack"
            ),
            FreeTierModelOption(
                provider: .applePCC,
                displayName: "Apple Private Cloud Compute (PCC)",
                costFact: "Free ($0/mo) — Included with Apple Intelligence; zero usage subscriptions.",
                privacyFact: "E2E Encrypted Apple Cloud — Cryptographically verifiable, stateless, no persistent logs.",
                speedFact: "Fast Cloud — Sub-second deep reasoning throughput with extended context.",
                recommendedWorkload: "Deep reasoning and complex synthesis requiring Apple Foundation Models.",
                isDefault: false,
                isPaid: false,
                iconName: "lock.icloud"
            ),
            FreeTierModelOption(
                provider: .cloudGemini,
                displayName: "Google Gemini Free Tier",
                costFact: "Free Tier ($0) — Google AI Studio developer tier (subject to provider quota).",
                privacyFact: "Cloud AI — Prompts processed on Google cloud infrastructure under API terms.",
                speedFact: "Very Fast — Cloud streaming with sub-second time-to-first-token.",
                recommendedWorkload: "Multimodal image inputs and ultra-long context analysis.",
                isDefault: false,
                isPaid: false,
                iconName: "sparkles"
            ),
            FreeTierModelOption(
                provider: .localMLX,
                displayName: "Local MLX-LM",
                costFact: "Free ($0/mo) — Apple Silicon native Metal framework execution.",
                privacyFact: "Local Only — Localhost memory residency with zero network telemetry.",
                speedFact: "Very Fast — Optimized Metal kernels with unified memory caching.",
                recommendedWorkload: "Local MLX-quantized models on high-RAM Apple Silicon hardware.",
                isDefault: false,
                isPaid: false,
                iconName: "bolt.fill"
            )
        ]
    }

    public func option(for provider: ModelProvider) -> FreeTierModelOption? {
        allOptions().first { $0.provider == provider }
    }

    // MARK: - Availability & Withdrawal State

    public func status(for provider: ModelProvider) -> ProviderAvailabilityStatus {
        lock.lock()
        defer { lock.unlock() }

        if let reason = inMemoryWithdrawals[provider] {
            return .withdrawn(reason: reason)
        }

        // Check environment variable APEX_WITHDRAWN_FREE_TIERS (e.g. "cloudGemini:Quota exhausted")
        if let env = ProcessInfo.processInfo.environment["APEX_WITHDRAWN_FREE_TIERS"] {
            for entry in env.split(separator: ",") {
                let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
                if let first = parts.first,
                   let parsed = ModelProvider.parse(first),
                   parsed == provider {
                    let reason = parts.count > 1 ? parts[1] : "Free tier withdrawn by provider."
                    return .withdrawn(reason: reason)
                }
            }
        }

        return .available
    }

    public func isWithdrawn(provider: ModelProvider) -> Bool {
        status(for: provider).isWithdrawn
    }

    public func withdrawalReason(provider: ModelProvider) -> String? {
        status(for: provider).explanation
    }

    /// Explicitly withdraws a free tier (e.g. when Gemini rate-limits to zero or shuts down its free tier).
    public func withdrawFreeTier(provider: ModelProvider, reason: String) {
        lock.lock()
        inMemoryWithdrawals[provider] = reason
        var stored = UserDefaults.standard.dictionary(forKey: Self.withdrawnDefaultsKey) as? [String: String] ?? [:]
        stored[provider.rawValue] = reason
        UserDefaults.standard.set(stored, forKey: Self.withdrawnDefaultsKey)
        lock.unlock()

        Self.logger.warning("Free tier for \(provider.displayName, privacy: .public) marked as WITHDRAWN: \(reason, privacy: .public)")
    }

    /// Reinstates a previously withdrawn free tier.
    public func reinstateFreeTier(provider: ModelProvider) {
        lock.lock()
        inMemoryWithdrawals.removeValue(forKey: provider)
        var stored = UserDefaults.standard.dictionary(forKey: Self.withdrawnDefaultsKey) as? [String: String] ?? [:]
        stored.removeValue(forKey: provider.rawValue)
        UserDefaults.standard.set(stored, forKey: Self.withdrawnDefaultsKey)
        lock.unlock()

        Self.logger.info("Free tier for \(provider.displayName, privacy: .public) REINSTATED.")
    }

    /// Resets all withdrawal flags (used for test isolation).
    public func resetAllWithdrawals() {
        lock.lock()
        inMemoryWithdrawals.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.withdrawnDefaultsKey)
        lock.unlock()
    }

    private func loadWithdrawals() {
        lock.lock()
        defer { lock.unlock() }
        if let stored = UserDefaults.standard.dictionary(forKey: Self.withdrawnDefaultsKey) as? [String: String] {
            for (key, reason) in stored {
                if let p = ModelProvider(rawValue: key) {
                    inMemoryWithdrawals[p] = reason
                }
            }
        }
    }

    // MARK: - Graceful Degradation (The Gemini CLI Lesson)

    /// Resolves the effective provider, automatically degrading to a local free provider
    /// if the preferred provider's free tier has been withdrawn.
    public func resolveGracefulDegradation(for preferred: ModelProvider) -> (
        provider: ModelProvider,
        degraded: Bool,
        explanation: String
    ) {
        let currentStatus = status(for: preferred)

        switch currentStatus {
        case .available:
            return (
                provider: preferred,
                degraded: false,
                explanation: "Provider '\(preferred.displayName)' is active and operational under free tier."
            )

        case .withdrawn(let reason):
            let fallback: ModelProvider = (preferred == .appleOnDevice) ? .localOllama : .appleOnDevice
            let explanation = "Provider '\(preferred.displayName)' free tier was withdrawn (\(reason)). ApexAgent has gracefully degraded to '\(fallback.displayName)'. All core workflows continue running on local silicon without paid billing."
            Self.logger.notice("Graceful degradation triggered: \(explanation, privacy: .public)")
            return (
                provider: fallback,
                degraded: true,
                explanation: explanation
            )

        case .unavailable(let reason):
            let fallback: ModelProvider = .appleOnDevice
            let explanation = "Provider '\(preferred.displayName)' is currently unavailable (\(reason)). ApexAgent has degraded to '\(fallback.displayName)'."
            return (
                provider: fallback,
                degraded: true,
                explanation: explanation
            )
        }
    }

    // MARK: - Configuration Application

    /// Applies the selected provider to the application configuration and active orchestrator.
    @MainActor
    public func applyProviderSelection(_ provider: ModelProvider, orchestrator: AgentOrchestrator? = nil) {
        let (effectiveProvider, degraded, explanation) = resolveGracefulDegradation(for: provider)

        ModelRegistry.setActiveProvider(effectiveProvider)

        let preference: AgentModelPreference = {
            switch effectiveProvider {
            case .appleOnDevice, .fmCLI: return .localSystem
            case .applePCC: return .privateCloud
            case .cloudGemini: return .cloudGemini
            case .localOllama: return .localOllama
            case .localMLX: return .localMLX
            case .autoPicker, .openAICompatible, .anthropic, .gitHubCopilot: return .autoPicker
            }
        }()

        UserDefaults.standard.set(preference.rawValue, forKey: "apex.modelPreference")

        if let orchestrator = orchestrator {
            orchestrator.modelPreference = preference
            orchestrator.resetSession()
        }

        if degraded {
            Self.logger.notice("Configured degraded provider: \(effectiveProvider.displayName, privacy: .public) — \(explanation, privacy: .public)")
        } else {
            Self.logger.info("Configured model provider from onboarding: \(effectiveProvider.displayName, privacy: .public)")
        }
    }

    // MARK: - Anti-Paid & Anti-Credit Guarantee

    /// Verifies that no paid model, credit purchase, or usage billing is presented anywhere in onboarding.
    public func validateZeroPaidBillingGuarantee() -> Bool {
        let options = allOptions()
        guard !options.isEmpty else { return false }

        // 1. Every option must be non-paid
        for opt in options {
            if opt.isPaid { return false }
            let lowerCost = opt.costFact.lowercased()
            if lowerCost.contains("credit card") || lowerCost.contains("usage-based") || lowerCost.contains("pay-as-you-go") {
                return false
            }
        }

        // 2. Default option must be 100% free local or auto
        guard let defaultOption = options.first(where: { $0.isDefault }) else { return false }
        if defaultOption.isPaid || defaultOption.provider == .openAICompatible || defaultOption.provider == .anthropic {
            return false
        }

        return true
    }
}
