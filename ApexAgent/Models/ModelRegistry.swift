import Foundation
import SwiftUI
import FoundationModels
import os

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
public enum ModelProvider: String, CaseIterable, Identifiable, Codable, Sendable, Hashable, Equatable {
    case autoPicker = "autoPicker"
    case appleOnDevice = "appleOnDevice"
    case applePCC = "applePCC"
    case cloudGemini = "cloudGemini"
    case localOllama = "localOllama"
    case localMLX = "localMLX"
    case fmCLI = "fmCLI"
    case openAICompatible = "openAICompatible"
    case anthropic = "anthropic"
    case gitHubCopilot = "gitHubCopilot"

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
        case .openAICompatible: return "OpenAI-Compatible REST (OpenAI, Groq, DeepSeek)"
        case .anthropic: return "Anthropic Claude API"
        case .gitHubCopilot: return "GitHub Copilot (GPT-4o, Claude 3.5 Sonnet, o1)"
        }
    }

    public static func parse(_ string: String) -> ModelProvider? {
        let lower = string.lowercased()
        if lower.contains("applefoundation") || lower.contains("foundationmodels") { return .appleOnDevice }
        if lower.contains("auto") { return .autoPicker }
        if lower.contains("ondevice") || lower.contains("on-device") || lower.contains("system") || (lower.contains("local") && !lower.contains("ollama") && !lower.contains("mlx")) { return .appleOnDevice }
        if lower.contains("pcc") || lower.contains("privatecloud") { return .applePCC }
        if lower.contains("gemini") { return .cloudGemini }
        if lower.contains("copilot") || lower.contains("github") { return .gitHubCopilot }
        if lower.contains("openai") || lower.contains("groq") || lower.contains("deepseek") || lower.contains("openrouter") { return .openAICompatible }
        if lower.contains("anthropic") || lower.contains("claude") { return .anthropic }
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
    case automatic
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
    public static let copilotModelKey = "apex.model.copilotModel"
    public static let copilotTokenKey = "apex.model.copilotToken"
    public static let ollamaHostKey = "apex.ollamaHostURL"
    public static let ollamaModelKey = "apex.ollamaModel"
    public static let mlxHostKey = "apex.mlxHostURL"
    public static let mlxModelKey = "apex.mlxModel"

    private static let migrateLegacyGeminiCredentials: Void = {
        guard !KeychainManager.isTestProcess else { return }
        let defaults = UserDefaults.standard
        let legacyDefaultsKeys = [geminiAPIKeyKey, "apex.geminiKey", "geminiAPIKey"]
        let legacyFile = ApexAgentStoragePaths.apex.appendingPathComponent("gemini_key")

        if let key = KeychainManager.get(key: "geminiAPIKey"), !key.isEmpty {
            for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
            removeLegacyGeminiFile(legacyFile)
            return
        }

        if let oldKey = KeychainManager.get(key: "apex.geminiKey"), !oldKey.isEmpty {
            guard KeychainManager.save(key: "geminiAPIKey", value: oldKey) else {
                AppLog.error(.registry, "Gemini API key migration from Keychain failed; legacy entry was retained.")
                return
            }
            _ = KeychainManager.delete(key: "apex.geminiKey")
            for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
            removeLegacyGeminiFile(legacyFile)
            return
        }

        if let legacyKey = legacyDefaultsKeys
            .compactMap({ defaults.string(forKey: $0) })
            .first(where: { !$0.isEmpty }) {
            guard KeychainManager.save(key: "geminiAPIKey", value: legacyKey) else {
                AppLog.error(.registry, "Gemini API key migration from UserDefaults failed; legacy entry was retained.")
                return
            }
            for key in legacyDefaultsKeys { defaults.removeObject(forKey: key) }
            removeLegacyGeminiFile(legacyFile)
            return
        }

        guard KeychainManager.migrateLegacyFile(at: legacyFile, toKey: "geminiAPIKey") else {
            AppLog.error(.registry, "Gemini API key migration from ~/.apex/gemini_key failed; legacy file was retained.")
            return
        }
    }()

    private static func removeLegacyGeminiFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLog.error(.registry, "Could not remove legacy Gemini key file: \(error.localizedDescription)")
        }
    }

    // Workload-specific default Ollama models
    public static let defaultFastOllamaModel = "gemma4:12b"
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

    /// Returns the effective provider for a specific bot (using bot override or global).
    static func effectiveProvider(for bot: BotProfile) -> ModelProvider {
        bot.modelProvider ?? activeProvider()
    }

    /// Returns the language model configured for a specific bot.
    static func model(for bot: BotProfile) -> any LanguageModel {
        let provider = effectiveProvider(for: bot)
        return model(for: .explicit(provider))
    }

    /// Estimates token count for prompt, history, instructions, and tools.
    static func estimateTokenCount(
        prompt: String = "",
        history: [ChatMessage] = [],
        instructions: String = "",
        tools: [String] = []
    ) -> Int {
        let textTokens = (prompt.count + instructions.count + history.reduce(0) { $0 + $1.content.count }) / 4
        let toolTokens = tools.count * 180
        return textTokens + toolTokens
    }

    /// Context window ceiling in tokens for a given model provider.
    public static func contextCeiling(for provider: ModelProvider) -> Int {
        switch provider {
        case .appleOnDevice: return 4_096
        case .localOllama, .localMLX, .fmCLI: return 8_192
        case .applePCC, .openAICompatible, .anthropic, .gitHubCopilot: return 32_768
        case .cloudGemini: return 1_000_000
        case .autoPicker: return 8_192
        }
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

    /// Retrieve the Gemini API key from Keychain, migrating legacy storage once.
    public static func geminiAPIKey() -> String {
        _ = migrateLegacyGeminiCredentials
        if let key = KeychainManager.get(key: "geminiAPIKey"), !key.isEmpty {
            return key
        }
        return ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }

    /// Sets the Gemini API key.
    @discardableResult
    public static func setGeminiAPIKey(_ key: String) -> Bool {
        _ = migrateLegacyGeminiCredentials
        let succeeded = KeychainManager.save(key: "geminiAPIKey", value: key)
        guard succeeded else {
            AppLog.info(.registry, "Gemini API key was not saved to Keychain.")
            return false
        }
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: geminiAPIKeyKey)
        defaults.removeObject(forKey: "apex.geminiKey")
        defaults.removeObject(forKey: "geminiAPIKey")
        return true
    }

    /// Sets the Gemini API key (alias for setGeminiAPIKey).
    @discardableResult
    public static func saveGeminiAPIKey(_ key: String) -> Bool {
        setGeminiAPIKey(key)
    }

    /// Supported Gemini model identifiers.
    public static let supportedGeminiModels = ["gemini-3.8-flash", "gemini-3.1-pro", "gemini-2.5-pro", "gemini-2.0-flash"]

    /// Returns the configured Gemini model name.
    public static func geminiModel() -> String {
        UserDefaults.standard.string(forKey: geminiModelKey) ?? "gemini-3.8-flash"
    }

    /// Sets the Gemini model name.
    public static func setGeminiModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: geminiModelKey)
    }

    /// Supported GitHub Copilot model identifiers.
    public static let supportedCopilotModels = ["gpt-4o", "claude-3.5-sonnet", "o1-preview", "gpt-4o-mini"]

    /// Returns the configured GitHub Copilot model name.
    public static func copilotModel() -> String {
        UserDefaults.standard.string(forKey: copilotModelKey) ?? "gpt-4o"
    }

    /// Sets the GitHub Copilot model name.
    public static func setCopilotModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: copilotModelKey)
    }

    /// Returns the configured GitHub Copilot personal / oauth token.
    public static func copilotToken() -> String {
        UserDefaults.standard.string(forKey: copilotTokenKey) ?? ""
    }

    /// Sets the GitHub Copilot personal / oauth token.
    public static func setCopilotToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: copilotTokenKey)
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

    private static let lastActiveOllamaModelLock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Currently active Ollama model tracked for single-active-local-weights policy.
    public static var currentActiveOllamaModel: String? {
        lastActiveOllamaModelLock.withLock { $0 }
    }

    /// Resets the tracked active Ollama model (used for test isolation).
    public static func resetActiveOllamaModelForTesting() {
        lastActiveOllamaModelLock.withLock { $0 = nil }
    }

    /// Enforces a single-active-local-weights policy in unified memory by explicitly unloading previously resident Ollama models.
    @discardableResult
    public static func unloadPreviousOllamaModelIfNeeded(newModel: String) -> String? {
        let previousModel = lastActiveOllamaModelLock.withLock { current -> String? in
            let prev = current
            current = newModel
            return (prev != nil && prev != newModel) ? prev : nil
        }
        guard let modelToUnload = previousModel else { return nil }

        Task {
            let hostStr = ollamaHost()
            guard let host = URL(string: hostStr) else { return }
            let endpoint = host.appendingPathComponent("api/chat")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload: [String: Any] = [
                "model": modelToUnload,
                "keep_alive": 0
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: request)
            AppLog.info(.registry, "Unloaded previous Ollama weights for '\(modelToUnload)' (keep_alive: 0) to free unified memory.")
        }
        return modelToUnload
    }

    /// Returns true if the prompt suggests a math or analytical reasoning problem.
    public static func isTaskMathOrAnalytical(prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let mathTerms = [
            "calculate", "plus", "minus", "multiply", "divide", "square root",
            "derivative", "integral", "matrix", "equation", "solve", "math",
            "add", "subtract", "sum", "product"
        ]
        return mathTerms.contains { lower.contains($0) }
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
        resolveProviderForTask(
            preferred: preferred,
            prompt: prompt,
            history: [],
            instructions: instructions,
            tools: tools,
            hasAttachments: hasAttachments,
            isPCCAvailable: isPCCAvailable
        )
    }

    static func resolveProviderForTask(
        preferred: ModelProvider = .autoPicker,
        prompt: String = "",
        history: [ChatMessage] = [],
        instructions: String = "",
        tools: [String] = [],
        hasAttachments: Bool = false,
        isPCCAvailable: Bool = true
    ) -> (provider: ModelProvider, reason: String?) {
        let estimatedTokens = estimateTokenCount(prompt: prompt, history: history, instructions: instructions, tools: tools)

        if preferred != .autoPicker && preferred != .appleOnDevice {
            return (preferred, nil)
        }

        if isTaskMathOrAnalytical(prompt: prompt) {
            return (.localOllama, "Analytical / mathematical task routed to high-reasoning engine.")
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

        if estimatedTokens > 8000 && !geminiAPIKey().isEmpty {
            return (.cloudGemini, "Context tokens (\(estimatedTokens)) exceed local 8k ceiling; tiering to Cloud Gemini long-context engine.")
        }

        return (.localOllama, "Context tokens (\(estimatedTokens)) exceed safe limit (3.2k); Auto-tiering to Local Ollama.")
    }

    /// Creates and returns the FoundationModels `LanguageModel` for the given target.
    public static func model(for target: ModelTarget, apiKey: String? = nil) -> any LanguageModel {
        switch target {
        case .explicit(let provider):
            switch provider {
            case .appleOnDevice, .autoPicker:
                return SystemLanguageModel.default
            case .applePCC:
                return PrivateCloudComputeLanguageModel()
            case .fmCLI:
                return FMCLILanguageModel(backend: .system)
            case .cloudGemini:
                let key = (apiKey?.isEmpty == false) ? apiKey! : geminiAPIKey()
                return CloudGeminiLanguageModel(apiKey: key)
            case .localOllama:
                let url = URL(string: ollamaHost()) ?? URL(string: "http://localhost:11434")!
                return LocalOllamaLanguageModel(hostURL: url)
            case .localMLX:
                let urlStr = UserDefaults.standard.string(forKey: mlxHostKey) ?? "http://localhost:8080"
                let url = URL(string: urlStr) ?? URL(string: "http://localhost:8080")!
                return LocalMLXLanguageModel(hostURL: url)
            case .openAICompatible:
                return OpenAICompatibleLanguageModel()
            case .anthropic:
                return AnthropicLanguageModel()
            case .gitHubCopilot:
                let modelName = copilotModel()
                return GitHubCopilotLanguageModel(configuration: GitHubCopilotConfiguration(modelName: modelName))
            }
        case .automatic:
            let provider = activeProvider()
            if provider == .autoPicker {
                return SystemLanguageModel.default
            }
            return model(for: .explicit(provider), apiKey: apiKey)
        case .auto(let prompt):
            let (provider, _) = resolveProviderForTask(preferred: .autoPicker, prompt: prompt)
            return model(for: .explicit(provider), apiKey: apiKey)
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
        case .openAICompatible, .anthropic, .gitHubCopilot, .autoPicker:
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

// MARK: - ModelRegistry Markdown Extension
extension ModelRegistry {
    public static func formatSupportedProvidersTable() -> String {
        var md = "### 🤖 Supported Model Providers & Privacy Tiers\n\n"
        md += "| Provider Identifier | Display Name | Privacy Class |\n"
        md += "|---|---|---|\n"

        for p in ModelProvider.allCases {
            let privClass: String
            switch p {
            case .appleOnDevice, .fmCLI: privClass = "🔒 Strictly On-Device (0 outgoing network)"
            case .applePCC: privClass = "🛡️ Apple Private Cloud Compute (E2E Encrypted)"
            case .localOllama, .localMLX: privClass = "🏠 Local Self-Hosted Daemon"
            case .cloudGemini: privClass = "☁️ Google Gemini Cloud API"
            case .openAICompatible: privClass = "🌐 Universal OpenAI-Compatible API"
            case .anthropic: privClass = "☁️ Anthropic Claude Cloud API"
            case .gitHubCopilot: privClass = "🐙 GitHub Copilot Cloud API"
            case .autoPicker: privClass = "⚡️ Dynamic Balanced Routing"
            }
            md += "| `\(p.rawValue)` | **\(p.displayName)** | \(privClass) |\n"
        }
        return md
    }

}

extension AutoTieringStrategy {
    public var badge: String {
        switch self {
        case .balanced: return "⚖️ Balanced"
        case .cloudFirst: return "☁️ Performance First"
        case .localFirst: return "🏠 Local First"
        }
    }
}

extension ModelProvider {
    public var badge: String {
        switch self {
        case .autoPicker: return "🤖 Auto"
        case .appleOnDevice: return "🍎 On-Device"
        case .applePCC: return "🔒 PCC"
        case .cloudGemini: return "☁️ Gemini"
        case .localOllama: return "🦙 Ollama"
        case .localMLX: return "🧠 MLX"
        case .fmCLI: return "⌨️ FM CLI"
        case .openAICompatible: return "🌐 OpenAI"
        case .anthropic: return "🎭 Claude"
        case .gitHubCopilot: return "🐙 Copilot"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .appleOnDevice, .localOllama, .localMLX, .fmCLI: return true
        case .autoPicker, .applePCC, .cloudGemini, .openAICompatible, .anthropic, .gitHubCopilot: return false
        }
    }

    public var requiresNetwork: Bool { !isLocal && self != .autoPicker }
}

extension ModelTier {
    public var badge: String {
        switch self {
        case .standard: return "📦 Standard"
        case .reasoning: return "🧩 Reasoning"
        case .coding: return "💻 Coding"
        case .longContext: return "📜 Long Context"
        case .vision: return "👁️ Vision"
        case .fast: return "⚡️ Fast"
        }
    }
}

extension PrivacyTier {
    public var badge: String {
        switch self {
        case .strictlyOnDevice: return "🔒 On-Device Only"
        case .appleE2ECloud: return "🔐 Apple E2E Cloud"
        case .enterpriseLocal: return "🏢 Enterprise Local"
        case .fullCloud: return "☁️ Full Cloud"
        }
    }

    /// Ordering from most-private (0) to least-private (3).
    public var privacyRank: Int {
        switch self {
        case .strictlyOnDevice: return 0
        case .appleE2ECloud: return 1
        case .enterpriseLocal: return 2
        case .fullCloud: return 3
        }
    }

    /// True when this tier is at least as private as the requirement.
    public func satisfies(requirement: PrivacyTier) -> Bool {
        privacyRank <= requirement.privacyRank
    }
}

extension ModelRegistry {
    /// One-line routing summary for diagnostics surfaces.
    public static func routingSummaryMarkdown() -> String {
        let provider = activeProvider()
        let strategy = activeTieringStrategy()
        var md = "### 🧠 Model Routing: \(provider.badge) via \(strategy.badge)\n\n"
        md += "| Setting | Value |\n"
        md += "|---|---|\n"
        md += "| Provider | \(provider.badge) `\(provider.rawValue)` |\n"
        md += "| Strategy | \(strategy.badge) |\n"
        md += "| Local | \(provider.isLocal ? "✅ On-device" : "☁️ Remote") |\n"
        return md
    }
}
