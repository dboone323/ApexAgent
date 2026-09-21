import Foundation
import Synchronization
import FoundationModels

/// Central, single-Swift-API model selector for ApexAgent.
///
/// ApexAgent conforms to Apple's `LanguageModel` protocol across multiple
/// providers:
/// 1. Apple On-Device (AFM 3 via FoundationModels)
/// 2. Cloud Gemini (Flash / Pro via Google Generative AI API)
/// 3. Local Ollama (gemma4:12bmlx / llama / qwen on localhost:11434)
/// 4. Local MLX (gemma4:12bmlx on localhost:8080)
/// 5. Apple Private Cloud Compute (PCC)
/// 6. fm CLI (Apple on-device CLI)
///
/// The Auto Model Picker dynamically resolves the best LLM on each turn
/// based on context token size, task complexity, tool count, vision attachments,
/// and provider availability.
public enum ModelProvider: String, CaseIterable, Sendable {
    case autoPicker
    case appleOnDevice
    case applePCC
    case cloudGemini
    case localOllama
    case localMLX
    case fmCLI

    public var displayName: String {
        switch self {
        case .autoPicker: "Auto Model Picker (Native → Gemini Flash → Ollama)"
        case .appleOnDevice: "Apple On-Device (AFM 3)"
        case .applePCC: "Apple Private Cloud Compute"
        case .cloudGemini: "Cloud Gemini (Flash / Pro)"
        case .localOllama: "Local Ollama (gemma4:12bmlx)"
        case .localMLX: "Local MLX (gemma4:12bmlx)"
        case .fmCLI: "fm CLI (Apple)"
        }
    }
}

/// Represents an eligible provider candidate within a fallback chain.
public struct ProviderCandidate: Equatable, Sendable {
    public let provider: ModelProvider
    public let modelName: String?
    public let reason: String?
    public let priority: Int

    public init(provider: ModelProvider, modelName: String? = nil, reason: String? = nil, priority: Int = 0) {
        self.provider = provider
        self.modelName = modelName
        self.reason = reason
        self.priority = priority
    }
}

public enum ModelSelectionStrategy: Sendable {
    /// Use exactly the requested provider.
    case explicit(ModelProvider)
    /// Replicate the fallback chain: on-device (<=4k) → Gemini Flash (>4k / High-complexity) → Ollama → MLX.
    case automatic
}

public enum AutoTieringStrategy: String, CaseIterable, Identifiable {
    case balanced = "balanced"        // On-Device (0-3.2k) -> Local Ollama (3.2k-32k) -> Cloud Gemini (>32k + Vision)
    case cloudFirst = "cloudFirst"    // On-Device (0-3.2k) -> Cloud Gemini (>3.2k) -> Ollama fallback
    case localFirst = "localFirst"    // On-Device (0-3.2k) -> Local Ollama (>3.2k) -> Gemini fallback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .balanced:
            return "Balanced (Ollama 4k-32k, Gemini >32k)"
        case .cloudFirst:
            return "Performance First (Gemini >4k)"
        case .localFirst:
            return "Local First (Ollama >4k)"
        }
    }
}

public struct ModelRegistry {

    /// Keys mirrored from Settings & Keychain implementations.
    private static let geminiKeyKey = "apex.geminiKey"
    private static let geminiModelKey = "apex.geminiModel"
    private static let ollamaModelKey = "apex.ollamaModel"
    private static let mlxHostKey = "apex.mlxHost"
    private static let mlxModelKey = "apex.mlxModel"
    public static let providerKey = "apex.modelProvider"
    public static let tieringStrategyKey = "apex.autoTieringStrategy"

    /// Serializes the read-migrate-write cycle in `geminiAPIKey()` and the
    /// delete in `saveGeminiAPIKey()` so concurrent callers (e.g. parallel
    /// tests, or multi-agent provider resolution) can't race the legacy-key
    /// migration into writing a stale/real key back to the keychain right
    /// after a test (or logout) deleted it.
    private static let geminiKeyMutex = Mutex(())

    public static func activeTieringStrategy() -> AutoTieringStrategy {
        if let raw = UserDefaults.standard.string(forKey: tieringStrategyKey),
           let strategy = AutoTieringStrategy(rawValue: raw) {
            return strategy
        }
        return .balanced
    }

    /// Retrieves the Gemini API Key from Keychain (preferred) or environment.
    /// Automatically migrates any legacy plaintext keys in ~/.apex/gemini_key or UserDefaults to Keychain and purges them.
    public static func geminiAPIKey() -> String {
        geminiKeyMutex.withLock { _ in
        if let key = KeychainManager.get(key: "geminiAPIKey"), !key.isEmpty {
            return key
        }
        if let key = KeychainManager.get(key: geminiKeyKey), !key.isEmpty {
            return key
        }
        if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
            return envKey
        }

        // Automatic legacy migration: check file then UserDefaults
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apex/gemini_key")
        var legacyKey: String?
        if let fileKey = try? String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !fileKey.isEmpty {
            legacyKey = fileKey
            try? FileManager.default.removeItem(at: fileURL)
        } else if let udKey = UserDefaults.standard.string(forKey: geminiKeyKey) ?? UserDefaults.standard.string(forKey: "geminiAPIKey"), !udKey.isEmpty {
            legacyKey = udKey
        }

        // Purge legacy plaintext from UserDefaults
        UserDefaults.standard.removeObject(forKey: geminiKeyKey)
        UserDefaults.standard.removeObject(forKey: "geminiAPIKey")

        if let found = legacyKey, !found.isEmpty {
            KeychainManager.save(key: "geminiAPIKey", value: found)
            KeychainManager.save(key: geminiKeyKey, value: found)
            return found
        }
        return ""
        }
    }

    /// Persists the Gemini API Key securely in Keychain, purging any legacy plaintext file or UserDefaults entries.
    public static func saveGeminiAPIKey(_ key: String) {
        geminiKeyMutex.withLock { _ in
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainManager.delete(key: "geminiAPIKey")
            KeychainManager.delete(key: geminiKeyKey)
        } else {
            KeychainManager.save(key: "geminiAPIKey", value: trimmed)
            KeychainManager.save(key: geminiKeyKey, value: trimmed)
        }

        // Purge legacy plaintext storage
        UserDefaults.standard.removeObject(forKey: "geminiAPIKey")
        UserDefaults.standard.removeObject(forKey: geminiKeyKey)

        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apex/gemini_key")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        }
    }

    /// Default Gemini model to the latest Flash version (gemini-3.5-flash).
    public static func geminiModel() -> String {
        UserDefaults.standard.string(forKey: geminiModelKey) ?? "gemini-3.5-flash"
    }

    public static func ollamaModel() -> String {
        UserDefaults.standard.string(forKey: ollamaModelKey) ?? "gemma4:12b"
    }

    public static func mlxModel() -> String {
        UserDefaults.standard.string(forKey: mlxModelKey) ?? "gemma4:12bmlx"
    }

    public static func mlxHost() -> URL {
        let raw = UserDefaults.standard.string(forKey: mlxHostKey) ?? "http://localhost:8080"
        return URL(string: raw) ?? URL(string: "http://localhost:8080")!
    }

    /// Resolve the active provider from `UserDefaults` (`apex.modelProvider`),
    /// falling back to `.autoPicker`.
    public static func activeProvider() -> ModelProvider {
        if let raw = UserDefaults.standard.string(forKey: providerKey),
           let provider = ModelProvider(rawValue: raw) {
            return provider
        }
        return .autoPicker
    }

    /// Estimates the token count for a prompt, history, instructions, and tool definitions (~4 characters per token + ~180 tokens per tool schema).
    static func estimateTokenCount(prompt: String, history: [ChatMessage] = [], instructions: String = "", tools: [String] = []) -> Int {
        let historyChars = history.reduce(0) { $0 + $1.content.count }
        let totalChars = prompt.count + historyChars + instructions.count
        let toolTokens = tools.count * 180
        return max(1, (totalChars / 4) + toolTokens)
    }

    /// Resolves the optimal `ModelProvider` given task size, complexity, user preference, and system capabilities.
    ///
    /// Auto Model Picker Cascade:
    /// 1. Apple Native On-Device (AFM) for standard tasks (<= 3,200 tokens, quick conversational, local tools).
    /// 2. Local Ollama (gemma4:12b) for mid-size tasks (3,200–32,000 tokens) in Balanced mode to preserve cloud quota.
    /// 3. Cloud Gemini Flash / Pro for massive context (>32,000 tokens), deep multi-agent planning, and multimodal vision.
    /// 4. Apple PCC / Local MLX / fm CLI.
    static func resolveProviderForTask(
        preferred: ModelProvider?,
        prompt: String,
        history: [ChatMessage] = [],
        instructions: String = "",
        tools: [String] = [],
        hasAttachments: Bool = false,
        isPCCAvailable: Bool? = nil
    ) -> (provider: ModelProvider, reason: String?) {
        let targetProvider = preferred ?? activeProvider()
        let tokens = estimateTokenCount(prompt: prompt, history: history, instructions: instructions, tools: tools)
        let hasGeminiKey = !geminiAPIKey().isEmpty
        let pccAvailable = isPCCAvailable ?? AgentOrchestrator.isPrivateCloudComputeAvailable()
        let strategy = activeTieringStrategy()

        // If explicitly requested a specific fixed provider, honor it
        if targetProvider != .autoPicker && targetProvider != .appleOnDevice {
            return (targetProvider, nil)
        }

        // 1. Multimodal / Image attachments
        if hasAttachments {
            if hasGeminiKey {
                return (.cloudGemini, "Multimodal task with attachments. Auto-routing to Cloud Gemini Flash (high-fidelity vision).")
            }
            return (.appleOnDevice, "Multimodal task with attachments. Routing to Apple On-Device Vision.")
        }

        // 2. Context Window & Size overflow (>3,200 tokens exceeds on-device AFM 4k limit)
        if tokens > 3200 {
            switch strategy {
            case .cloudFirst:
                if hasGeminiKey {
                    let model = geminiModel()
                    return (.cloudGemini, "Task context is ~\(tokens) tokens (>4k safe limit). Auto-tiering to Cloud Gemini (\(model)).")
                } else if pccAvailable {
                    return (.applePCC, "Task context is ~\(tokens) tokens (>4k safe limit). Auto-tiering to Apple Private Cloud Compute.")
                } else {
                    return (.localOllama, "Task context is ~\(tokens) tokens (>4k safe limit) and Cloud Gemini is unkeyed. Auto-tiering to Local Ollama (\(ollamaModel())).")
                }

            case .balanced:
                // Balanced mode:
                // - High complexity or very large context (>32k tokens) routes to Cloud Gemini (fast, prevents local GPU strain).
                // - If Apple PCC is available, use PCC for mid-size tasks (>3.2k) before taxing local Ollama resources.
                // - Otherwise route to Local Ollama in the 3.2k-32k window to preserve Gemini quota!
                let isComplex = isTaskHighComplexity(prompt: prompt, instructions: instructions, tools: tools)
                if (tokens > 32000 || isComplex) && hasGeminiKey {
                    let model = geminiModel()
                    let reason = tokens > 32000
                        ? "Large context (~\(tokens) tokens > 32k). Auto-tiering to Cloud Gemini (\(model)) for high-speed cloud reasoning."
                        : "High-complexity architecture task. Auto-routing to Cloud Gemini (\(model)) for deep reasoning."
                    return (.cloudGemini, reason)
                } else if pccAvailable {
                    return (.applePCC, "Task context is ~\(tokens) tokens (>3.2k). Auto-tiering to Apple Private Cloud Compute.")
                } else {
                    return (.localOllama, "Task context is ~\(tokens) tokens (3.2k–32k band). Preserving Gemini API quota with Local Ollama (\(ollamaModel())).")
                }

            case .localFirst:
                if pccAvailable && tokens > 32000 {
                    return (.applePCC, "Task context is ~\(tokens) tokens (>32k limit). Auto-tiering to Apple Private Cloud Compute.")
                }
                return (.localOllama, "Task context is ~\(tokens) tokens. Local First mode active (\(ollamaModel())).")
            }
        }

        // 3. Mathematical & Analytical Calculation (auto-routes to cloud or deep local model when in autoPicker)
        if targetProvider == .autoPicker && isTaskMathOrAnalytical(prompt: prompt) {
            if hasGeminiKey && strategy == .cloudFirst {
                let model = geminiModel()
                return (.cloudGemini, "Mathematical calculation detected. Auto-routing to Cloud Gemini (\(model)) for AI reasoning.")
            } else if pccAvailable {
                return (.applePCC, "Mathematical calculation detected. Auto-routing to Apple Private Cloud Compute.")
            } else {
                return (.localOllama, "Mathematical calculation detected. Auto-routing to Local Ollama (\(ollamaModel())) for AI reasoning.")
            }
        }

        // 4. Complexity heuristic (deep coding / large multi-file refactoring / heavy playbook orchestration)
        if targetProvider == .autoPicker && isTaskHighComplexity(prompt: prompt, instructions: instructions, tools: tools) {
            if hasGeminiKey {
                let model = geminiModel()
                return (.cloudGemini, "High-complexity architecture/code task detected. Auto-routing to Cloud Gemini (\(model)) for deep reasoning.")
            }
        }

        // 5. Default Tier 1: Apple Native on-device
        if targetProvider == .autoPicker || targetProvider == .appleOnDevice {
            return (.appleOnDevice, nil)
        }

        return (targetProvider, nil)
    }

    /// Evaluates if the task involves mathematical calculations, arithmetic, or analytical reasoning.
    public static func isTaskMathOrAnalytical(prompt: String) -> Bool {
        let text = prompt.lowercased()
        let mathKeywords = [
            "calculate", "arithmetic", "equation", "formula", "integral", "derivative",
            "algebra", "two plus two", "2+2", "2 + 2", "plus", "minus",
            "multiplied by", "divided by", "square root", "factorial"
        ]
        return mathKeywords.contains { text.contains($0) }
    }

    /// Evaluates if the task has high architectural or reasoning complexity.
    public static func isTaskHighComplexity(prompt: String, instructions: String = "", tools: [String] = []) -> Bool {
        let text = (prompt + " " + instructions).lowercased()
        let complexityKeywords = [
            "refactor", "architecture", "playbook", "security review",
            "full pr review", "migration", "benchmark", "multi-agent", "convene_meeting",
            "optimize performance", "debug crash", "codebase overhaul"
        ]
        let matches = complexityKeywords.filter { text.contains($0) }
        return matches.count >= 2 || tools.contains("convene_meeting")
    }

    /// Creates an `AgentEngine` for a specific `ModelProvider`.
    /// Sole instantiation path used by `ProviderFallbackExecutor` for canonical
    /// runtime routing (candidate planning + bounded fallback + tool governance).
    /// Nothing outside the fallback executor may construct an engine directly.
    @MainActor
    static func engine(
        for provider: ModelProvider,
        bot: BotProfile? = nil,
        session: LanguageModelSession? = nil,
        orchestrator: AgentOrchestrator
    ) -> any AgentEngine {
        let botAllowedTools: [String]? = if let bot, !bot.allowedToolNames.isEmpty {
            bot.allowedToolNames
        } else {
            nil
        }

        switch provider {
        case .autoPicker, .appleOnDevice, .applePCC, .fmCLI:
            return NativeAppleEngine(orchestrator: orchestrator, customSession: session)
        case .cloudGemini:
            if !geminiAPIKey().isEmpty {
                let geminiModel = CloudGeminiLanguageModel(apiKey: geminiAPIKey())
                let geminiSession: LanguageModelSession
                if let existingSession = session {
                    geminiSession = existingSession
                } else {
                    let profile = SupervisorAgentProfile(
                        instructions: "",
                        model: geminiModel,
                        toolCallingMode: .allowed,
                        orchestrator: orchestrator,
                        reasoningLevel: nil,
                        maxResponseTokens: nil
                    )
                    geminiSession = LanguageModelSession(profile: profile, history: Transcript(entries: []))
                }
                return NativeAppleEngine(orchestrator: orchestrator, customSession: geminiSession)
            } else {
                return OllamaAgentEngine(orchestrator: orchestrator, bot: bot, allowedTools: botAllowedTools)
            }
        case .localOllama:
            return OllamaAgentEngine(orchestrator: orchestrator, bot: bot, allowedTools: botAllowedTools)
        case .localMLX:
            return MLXAgentEngine(orchestrator: orchestrator, bot: bot)
        }
    }

    /// Builds a prioritized, deduplicated fallback candidate chain.
    static func buildCandidateChain(
        preferred: ModelProvider? = nil,
        bot: BotProfile? = nil,
        prompt: String = "",
        history: [ChatMessage] = [],
        instructions: String = "",
        tools: [String] = [],
        hasAttachments: Bool = false
    ) -> [ProviderCandidate] {
        let preferredTarget = preferred ?? bot?.modelProvider ?? activeProvider()
        let (primary, primaryReason) = resolveProviderForTask(
            preferred: preferredTarget,
            prompt: prompt,
            history: history,
            instructions: instructions,
            tools: tools,
            hasAttachments: hasAttachments
        )

        var candidates: [ProviderCandidate] = []
        var seenProviders: Set<ModelProvider> = []

        func addCandidate(_ provider: ModelProvider, reason: String?, modelName: String? = nil) {
            guard !seenProviders.contains(provider) else { return }
            seenProviders.insert(provider)
            candidates.append(ProviderCandidate(
                provider: provider,
                modelName: modelName,
                reason: reason,
                priority: candidates.count
            ))
        }

        let primaryModelName: String? = switch primary {
        case .cloudGemini: geminiModel()
        case .localOllama: bot?.ollamaModelOverride ?? ollamaModel()
        case .localMLX: mlxModel()
        default: nil
        }
        addCandidate(primary, reason: primaryReason ?? "Primary selected provider", modelName: primaryModelName)

        let hasGeminiKey = !geminiAPIKey().isEmpty
        if hasGeminiKey {
            addCandidate(.cloudGemini, reason: "Cloud Gemini fallback", modelName: geminiModel())
        }
        addCandidate(.localOllama, reason: "Local Ollama fallback", modelName: bot?.ollamaModelOverride ?? ollamaModel())
        addCandidate(.appleOnDevice, reason: "Apple On-Device fallback")
        addCandidate(.localMLX, reason: "Local MLX fallback", modelName: mlxModel())

        return candidates
    }

    /// Build a `LanguageModel` for the given strategy.
    public static func model(
        for strategy: ModelSelectionStrategy = .automatic,
        apiKey: String? = nil
    ) -> any LanguageModel {
        let provider: ModelProvider = switch strategy {
        case .explicit(let p): p
        case .automatic: activeProvider()
        }

        switch provider {
        case .autoPicker, .appleOnDevice:
            return SystemLanguageModel.default
        case .applePCC:
            return PrivateCloudComputeLanguageModel()
        case .cloudGemini:
            return CloudGeminiLanguageModel(apiKey: apiKey ?? geminiAPIKey())
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            return LocalOllamaLanguageModel(hostURL: host)
        case .localMLX:
            return LocalMLXLanguageModel(hostURL: mlxHost())
        case .fmCLI:
            return FMCLILanguageModel()
        }
    }

    /// Build a `LanguageModel` for a specific Bot, respecting per-bot overrides.
    static func model(
        for bot: BotProfile,
        apiKey: String? = nil
    ) -> any LanguageModel {
        let provider = bot.modelProvider ?? activeProvider()
        return model(for: .explicit(provider), apiKey: apiKey)
    }

    /// Resolve the effective `ModelProvider` for a Bot — its own override,
    /// or the global default.
    static func effectiveProvider(for bot: BotProfile) -> ModelProvider {
        bot.modelProvider ?? activeProvider()
    }
}

extension AgentModelPreference {
    public var toModelProvider: ModelProvider {
        switch self {
        case .autoPicker: .autoPicker
        case .localSystem: .appleOnDevice
        case .privateCloud: .applePCC
        case .cloudGemini: .cloudGemini
        case .localOllama: .localOllama
        case .localMLX: .localMLX
        case .hybrid: .applePCC
        }
    }
}
