import Foundation
import SwiftUI
import FoundationModels

// MARK: - Auto Tiering Routing Strategy
public enum AutoTieringStrategy: String, CaseIterable, Identifiable, Codable, Sendable {
    case balanced = "balanced"
    case cloudFirst = "cloudFirst"
    case localFirst = "localFirst"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .balanced:
            return "Balanced (AFM 3 → Ollama → Gemini)"
        case .cloudFirst:
            return "Performance First (AFM 3 → Gemini → Ollama)"
        case .localFirst:
            return "Local First (AFM 3 → Ollama)"
        }
    }
}

// MARK: - Model Provider
public enum ModelProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case autoPicker = "autoPicker"
    case appleOnDevice = "appleOnDevice"
    case applePCC = "applePCC"
    case cloudGemini = "cloudGemini"
    case localOllama = "localOllama"
    case localMLX = "localMLX"
    case fmCLI = "fmCLI"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .autoPicker: return "Auto (Balanced AFM 3 → Cloud Gemini → Ollama)"
        case .appleOnDevice: return "Apple Intelligence (AFM 3 On-Device)"
        case .applePCC: return "Apple Private Cloud Compute (PCC)"
        case .cloudGemini: return "Google Gemini Cloud"
        case .localOllama: return "Local Ollama"
        case .localMLX: return "Local MLX-LM"
        case .fmCLI: return "Apple FoundationModels CLI"
        }
    }

    public static func parse(_ string: String) -> ModelProvider? {
        let lower = string.lowercased()
        if lower.contains("auto") { return .autoPicker }
        if lower.contains("ondevice") || lower.contains("on-device") || lower.contains("system") || (lower.contains("local") && !lower.contains("ollama") && !lower.contains("mlx")) { return .appleOnDevice }
        if lower.contains("pcc") || lower.contains("privatecloud") { return .applePCC }
        if lower.contains("gemini") { return .cloudGemini }
        if lower.contains("ollama") { return .localOllama }
        if lower.contains("mlx") { return .localMLX }
        if lower.contains("cli") { return .fmCLI }
        return ModelProvider(rawValue: string)
    }

    public static func from(preference: String) -> ModelProvider {
        parse(preference) ?? .autoPicker
    }
}

// MARK: - Model Target
public enum ModelTarget: Sendable {
    case explicit(ModelProvider)
    case auto(String)
}

// MARK: - Model Tier
public enum ModelTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard = "standard"
    case reasoning = "reasoning"
    case coding = "coding"
    case longContext = "longContext"
    case vision = "vision"
    case fast = "fast"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: return "Standard (AFM 3)"
        case .reasoning: return "Deep Reasoning (PCC / Gemma 4 / Qwen)"
        case .coding: return "Coding Specialist (Qwen 2.5 Coder)"
        case .longContext: return "Long Context (>32k tokens)"
        case .vision: return "Multimodal Vision (Gemini / Apple Vision)"
        case .fast: return "Fast Response (AFM 3 / Llama 3.2 3B)"
        }
    }
}

// MARK: - Privacy Tier
public enum PrivacyTier: String, CaseIterable, Identifiable, Codable, Sendable {
    case strictlyOnDevice = "strictlyOnDevice"
    case appleE2ECloud = "appleE2ECloud"
    case enterpriseLocal = "enterpriseLocal"
    case fullCloud = "fullCloud"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strictlyOnDevice: return "Strictly On-Device (0 bytes leave device)"
        case .appleE2ECloud: return "Apple Private Cloud Compute (E2E Encrypted)"
        case .enterpriseLocal: return "Local Server / Ollama / MLX"
        case .fullCloud: return "Cloud AI (Gemini 2.5 Flash / Pro)"
        }
    }
}

// MARK: - Model Registry
public struct ModelRegistry: Sendable {
    public static let privacyTierKey = "apex.privacyTier"
    public static let tieringStrategyKey = "apex.tieringStrategy"
    public static let providerKey = "apex.model.provider"
    public static let geminiAPIKeyKey = "apex.model.geminiAPIKey"
    public static let geminiModelKey = "apex.model.geminiModel"
    public static let ollamaHostKey = "apex.ollamaHostURL"
    public static let ollamaModelKey = "apex.ollamaModel"
    public static let mlxHostKey = "apex.mlxHostURL"
    public static let mlxModelKey = "apex.mlxModel"

    // Workload-specific default Ollama models
    public static let defaultFastOllamaModel = "llama3.2:3b"
    public static let defaultCodingOllamaModel = "qwen2.5-coder:7b"
    public static let defaultResearchOllamaModel = "gemma4:12b"
    public static let defaultAutomationOllamaModel = "qwen2.5-coder:7b"

    /// Returns the active AutoTieringStrategy configured by the user.
    public static func activeTieringStrategy() -> AutoTieringStrategy {
        if let raw = UserDefaults.standard.string(forKey: tieringStrategyKey),
           let strat = AutoTieringStrategy(rawValue: raw) {
            return strat
        }
        return .balanced
    }

    /// Sets the active AutoTieringStrategy.
    public static func setTieringStrategy(_ strategy: AutoTieringStrategy) {
        UserDefaults.standard.set(strategy.rawValue, forKey: tieringStrategyKey)
    }

    /// Returns the currently active global provider.
    public static func activeProvider() -> ModelProvider {
        if let raw = UserDefaults.standard.string(forKey: providerKey),
           let provider = ModelProvider.parse(raw) {
            return provider
        }
        return .autoPicker
    }

    /// Sets the currently active global provider.
    public static func setActiveProvider(_ provider: ModelProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: providerKey)
    }

    /// Returns the currently active privacy tier.
    public static func privacyTier() -> PrivacyTier {
        guard let raw = UserDefaults.standard.string(forKey: privacyTierKey),
              let tier = PrivacyTier(rawValue: raw) else {
            return .strictlyOnDevice
        }
        return tier
    }

    /// Sets the privacy tier.
    public static func setPrivacyTier(_ tier: PrivacyTier) {
        UserDefaults.standard.set(tier.rawValue, forKey: privacyTierKey)
    }

    /// Retrieve the Gemini API key from Keychain, falling back to UserDefaults or environment variable.
    public static func geminiAPIKey() -> String {
        if let key = KeychainManager.get(key: "geminiAPIKey"), !key.isEmpty {
            return key
        }
        if let key = UserDefaults.standard.string(forKey: geminiAPIKeyKey), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }

    /// Sets the Gemini API key.
    public static func setGeminiAPIKey(_ key: String) {
        KeychainManager.save(key: "geminiAPIKey", value: key)
        UserDefaults.standard.set(key, forKey: geminiAPIKeyKey)
    }

    /// Sets the Gemini API key (alias for setGeminiAPIKey).
    public static func saveGeminiAPIKey(_ key: String) {
        setGeminiAPIKey(key)
    }

    /// Returns the configured Gemini model name.
    public static func geminiModel() -> String {
        UserDefaults.standard.string(forKey: geminiModelKey) ?? "gemini-2.5-flash"
    }

    /// Sets the Gemini model name.
    public static func setGeminiModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: geminiModelKey)
    }

    /// Returns the configured Ollama host URL.
    public static func ollamaHost() -> String {
        UserDefaults.standard.string(forKey: ollamaHostKey) ?? "http://localhost:11434"
    }

    /// Sets the Ollama host URL.
    public static func setOllamaHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: ollamaHostKey)
    }

    /// Returns the configured Ollama model name.
    public static func ollamaModel() -> String {
        UserDefaults.standard.string(forKey: ollamaModelKey) ?? defaultFastOllamaModel
    }

    /// Sets the Ollama model name.
    public static func setOllamaModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: ollamaModelKey)
    }

    /// Dynamically selects an appropriate workload-tiered Ollama model based on bot profile or role title.
    /// Fast lightweight models (`llama3.2:3b`) for general chat / assistant;
    /// Deep coder models (`qwen2.5-coder:7b`) for code architects & engineering;
    /// Deep research models (`gemma4:12b` or `qwen2.5:14b`) for researcher & data synthesis.
    static func ollamaModel(
        for bot: BotProfile? = nil,
        role: String? = nil,
        prompt: String? = nil
    ) -> String {
        if let override = bot?.ollamaModelOverride, !override.isEmpty {
            return override
        }

        let combined = [
            bot?.name ?? "",
            bot?.title ?? "",
            role ?? "",
            bot?.systemInstructions ?? "",
            prompt ?? ""
        ].joined(separator: " ").lowercased()

        if combined.contains("architect") || combined.contains("coder") || combined.contains("engineer") || combined.contains("refactor") || combined.contains("swift") || combined.contains("compiler") || combined.contains("code") {
            return defaultCodingOllamaModel
        }

        if combined.contains("research") || combined.contains("analyst") || combined.contains("synthesis") || combined.contains("deep dive") || combined.contains("survey") {
            return defaultResearchOllamaModel
        }

        if combined.contains("automator") || combined.contains("devops") || combined.contains("bash") || combined.contains("terminal") {
            return defaultAutomationOllamaModel
        }

        return defaultFastOllamaModel
    }

    /// Resolves the optimal provider for a task.
    public static func resolveProviderForTask(
        preferred: ModelProvider = .autoPicker,
        prompt: String = "",
        instructions: String = "",
        tools: [String] = [],
        hasAttachments: Bool = false,
        isPCCAvailable: Bool = true
    ) -> (provider: ModelProvider, reason: String?) {
        let estimatedTokens = (prompt.count + instructions.count) / 4

        if preferred != .autoPicker && preferred != .appleOnDevice {
            return (preferred, nil)
        }

        if estimatedTokens <= 3200 && !hasAttachments {
            return (.appleOnDevice, nil)
        }

        if isPCCAvailable && preferred == .appleOnDevice {
            return (.applePCC, "Context tokens (\(estimatedTokens)) exceed 3.2k on-device ceiling; tiering to Apple Private Cloud Compute.")
        }

        if hasAttachments && !geminiAPIKey().isEmpty {
            return (.cloudGemini, "Attachments require multimodal vision processing; tiering to Cloud Gemini.")
        }

        return (.localOllama, "Context tokens (\(estimatedTokens)) exceed 3.2k limit; auto-tiering to Local Ollama.")
    }

    /// Creates and returns the FoundationModels `LanguageModel` for the given target.
    public static func model(for target: ModelTarget) -> any LanguageModel {
        switch target {
        case .explicit(let provider):
            switch provider {
            case .appleOnDevice, .applePCC, .autoPicker, .fmCLI:
                return SystemLanguageModel.default
            case .cloudGemini:
                return CloudGeminiLanguageModel(apiKey: geminiAPIKey())
            case .localOllama:
                let url = URL(string: ollamaHost()) ?? URL(string: "http://localhost:11434")!
                return LocalOllamaLanguageModel(hostURL: url)
            case .localMLX:
                let urlStr = UserDefaults.standard.string(forKey: mlxHostKey) ?? "http://localhost:8080"
                let url = URL(string: urlStr) ?? URL(string: "http://localhost:8080")!
                return LocalMLXLanguageModel(hostURL: url)
            }
        case .auto(let prompt):
            let (provider, _) = resolveProviderForTask(preferred: .autoPicker, prompt: prompt)
            return model(for: .explicit(provider))
        }
    }

    /// Builds a candidate fallback chain based on user preference, bot configuration, context budget, and workload tier.
    static func buildCandidateChain(
        preferred: ModelProvider? = .autoPicker,
        bot: BotProfile? = nil,
        prompt: String = "",
        history: [ChatMessage] = [],
        instructions: String = "",
        tools: [String] = [],
        hasAttachments: Bool = false
    ) -> [ProviderCandidate] {
        var candidates: [ProviderCandidate] = []
        let estimatedTokens = (prompt.count + instructions.count + history.reduce(0) { $0 + $1.content.count }) / 4
        let strategy = activeTieringStrategy()
        let target = preferred ?? .autoPicker

        if target != .autoPicker {
            candidates.append(ProviderCandidate(provider: target, modelName: target == .localOllama ? ollamaModel(for: bot, prompt: prompt) : nil, reason: "User or Bot Preferred: \(target.displayName)", priority: 1))
            if target != .localOllama {
                candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Fallback", priority: 2))
            }
            if target != .cloudGemini && !geminiAPIKey().isEmpty {
                candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "Cloud Gemini Fallback", priority: 3))
            }
            if target != .appleOnDevice {
                candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "On-Device AFM Fallback", priority: 4))
            }
            return candidates
        }

        // Auto Tiering logic
        if hasAttachments {
            if !geminiAPIKey().isEmpty {
                candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "Multimodal Vision (Gemini)", priority: 1))
            }
            candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Fallback", priority: 2))
            candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "On-Device Fallback", priority: 3))
            return candidates
        }

        switch strategy {
        case .balanced:
            if estimatedTokens <= 3200 {
                candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "Fast on-device response (<=3.2k tokens)", priority: 1))
                candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Fallback", priority: 2))
                if !geminiAPIKey().isEmpty {
                    candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "Cloud Gemini Fallback", priority: 3))
                }
            } else if estimatedTokens <= 32000 {
                candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Specialist (3.2k-32k tokens)", priority: 1))
                if !geminiAPIKey().isEmpty {
                    candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "Cloud Gemini Fallback", priority: 2))
                }
                candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "On-Device Fallback", priority: 3))
            } else {
                if !geminiAPIKey().isEmpty {
                    candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "Large Context Cloud Processing (>32k tokens)", priority: 1))
                }
                candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Fallback", priority: 2))
            }

        case .cloudFirst:
            if estimatedTokens <= 3200 {
                candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "Fast on-device response (<=3.2k tokens)", priority: 1))
            }
            if !geminiAPIKey().isEmpty {
                candidates.append(ProviderCandidate(provider: .cloudGemini, modelName: geminiModel(), reason: "High Performance Cloud Gemini", priority: candidates.isEmpty ? 1 : 2))
            }
            candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Fallback", priority: candidates.count + 1))

        case .localFirst:
            candidates.append(ProviderCandidate(provider: .appleOnDevice, reason: "Strict Local On-Device AFM", priority: 1))
            candidates.append(ProviderCandidate(provider: .localOllama, modelName: ollamaModel(for: bot, prompt: prompt), reason: "Local Ollama Specialist", priority: 2))
        }

        return candidates
    }

    /// Returns the corresponding execution engine for the given provider.
    @MainActor
    static func engine(
        for provider: ModelProvider,
        bot: BotProfile? = nil,
        session: LanguageModelSession? = nil,
        allowedTools: [String]? = nil,
        orchestrator: AgentOrchestrator
    ) -> any AgentEngine {
        switch provider {
        case .appleOnDevice, .applePCC:
            return NativeAppleEngine(orchestrator: orchestrator, customSession: session)
        case .fmCLI:
            return FMCLIAgentEngine(orchestrator: orchestrator, backend: .system)
        case .cloudGemini:
            return GeminiAgentEngine(orchestrator: orchestrator, bot: bot, allowedTools: allowedTools)
        case .localOllama:
            return OllamaStreamingEngine(orchestrator: orchestrator, bot: bot, allowedTools: allowedTools)
        case .localMLX:
            return MLXAgentEngine(orchestrator: orchestrator, bot: bot)
        case .autoPicker:
            return NativeAppleEngine(orchestrator: orchestrator, customSession: session)
        }
    }
}

// MARK: - AgentModelPreference Bridge
extension AgentModelPreference {
    public var toModelProvider: ModelProvider {
        switch self {
        case .autoPicker: return .autoPicker
        case .localSystem: return .appleOnDevice
        case .privateCloud: return .applePCC
        case .cloudGemini: return .cloudGemini
        case .localOllama: return .localOllama
        case .localMLX: return .localMLX
        case .hybrid: return .applePCC
        }
    }
}
