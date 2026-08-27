import Foundation
import FoundationModels

/// Central, single-Swift-API model selector for ApexAgent.
///
/// ApexAgent already conforms to Apple's `LanguageModel` protocol for several
/// providers (Apple on-device, Apple Private Cloud Compute, Cloud Gemini,
/// Local Ollama, Local MLX). The individual tools historically duplicated the
/// same `UserDefaults`-keyed fallback chain inline. `ModelRegistry` unifies that
/// logic behind one API so every caller can swap providers with a single call,
/// matching the WWDC26 "one Swift API for any LLM" direction.
///
/// New in macOS 27: the `fm` command-line tool (`/usr/bin/fm`) exposes the
/// on-device Apple Foundation Model and the Private Cloud Compute server model.
/// `FMCLILanguageModel` (see FMCLILanguageModel.swift) conforms to the same
/// `LanguageModel` protocol by shelling out to `fm`, so it slots into this
/// registry like any other provider.
public enum ModelProvider: String, CaseIterable, Sendable {
    case appleOnDevice
    case applePCC
    case localOllama
    case localMLX
    case cloudGemini
    case fmCLI

    public var displayName: String {
        switch self {
        case .appleOnDevice: "Apple On-Device (Auto-tiers to PCC / Ollama >4k)"
        case .applePCC: "Apple Private Cloud Compute"
        case .localOllama: "Local Ollama (gemma4:12bmlx)"
        case .localMLX: "Local MLX (gemma4:12bmlx)"
        case .cloudGemini: "Cloud Gemini"
        case .fmCLI: "fm CLI (Apple)"
        }
    }
}

public enum ModelSelectionStrategy: Sendable {
    /// Use exactly the requested provider.
    case explicit(ModelProvider)
    /// Replicate the fallback chain used by the tools:
    /// on-device (<=4k) → PCC (>4k) → Ollama gemma4:12bmlx → MLX.
    case automatic
}

public struct ModelRegistry {

    /// Keys mirrored from the existing tool implementations.
    private static let geminiKeyKey = "apex.geminiKey"
    private static let ollamaModelKey = "apex.ollamaModel"
    private static let mlxHostKey = "apex.mlxHost"
    private static let mlxModelKey = "apex.mlxModel"
    public static let providerKey = "apex.modelProvider"

    public static func geminiAPIKey() -> String {
        UserDefaults.standard.string(forKey: geminiKeyKey) ?? ""
    }

    public static func ollamaModel() -> String {
        UserDefaults.standard.string(forKey: ollamaModelKey) ?? "gemma4:12bmlx"
    }

    public static func mlxModel() -> String {
        UserDefaults.standard.string(forKey: mlxModelKey) ?? "gemma4:12bmlx"
    }

    public static func mlxHost() -> URL {
        let raw = UserDefaults.standard.string(forKey: mlxHostKey) ?? "http://localhost:8080"
        return URL(string: raw) ?? URL(string: "http://localhost:8080")!
    }

    /// Resolve the active provider from `UserDefaults` (`apex.modelProvider`),
    /// falling back to `.appleOnDevice`.
    public static func activeProvider() -> ModelProvider {
        if let raw = UserDefaults.standard.string(forKey: providerKey),
           let provider = ModelProvider(rawValue: raw) {
            return provider
        }
        return .appleOnDevice
    }

    /// Estimates the token count for a prompt, history, and instructions (~4 characters per token).
    static func estimateTokenCount(prompt: String, history: [ChatMessage] = [], instructions: String = "") -> Int {
        let historyChars = history.reduce(0) { $0 + $1.content.count }
        let totalChars = prompt.count + historyChars + instructions.count
        return max(1, totalChars / 4)
    }

    /// Resolves the optimal `ModelProvider` given the task size, user preference, and system capabilities.
    ///
    /// Fallback hierarchy when a task exceeds on-device Apple Foundation Model 4k limit (~3,800 tokens):
    /// 1. Try Apple Private Cloud Compute (`.applePCC`) if available.
    /// 2. Third option: Local Ollama (`.localOllama`, running `gemma4:12bmlx` for macOS 27).
    /// 3. Local MLX (`.localMLX`, running `gemma4:12bmlx`).
    static func resolveProviderForTask(
        preferred: ModelProvider?,
        prompt: String,
        history: [ChatMessage] = [],
        instructions: String = "",
        isPCCAvailable: Bool? = nil
    ) -> (provider: ModelProvider, reason: String?) {
        let targetProvider = preferred ?? activeProvider()
        let tokens = estimateTokenCount(prompt: prompt, history: history, instructions: instructions)
        let pccAvailable = isPCCAvailable ?? AgentOrchestrator.isPrivateCloudComputeAvailable()

        // Only auto-tier when set to on-device or default
        if targetProvider == .appleOnDevice && tokens > 3800 {
            if pccAvailable {
                return (.applePCC, "Task context is ~\(tokens) tokens (>4k limit). Auto-tiering to Apple Private Cloud Compute.")
            } else {
                return (.localOllama, "Task context is ~\(tokens) tokens (>4k limit) and PCC is unavailable. Auto-tiering to Local Ollama (gemma4:12bmlx).")
            }
        }

        return (targetProvider, nil)
    }

    /// Creates the appropriate `AgentEngine` with automatic context-overflow routing.
    @MainActor
    static func resolveEngine(
        for bot: BotProfile? = nil,
        prompt: String = "",
        history: [ChatMessage] = [],
        instructions: String = "",
        orchestrator: AgentOrchestrator
    ) -> any AgentEngine {
        let preferred = bot?.modelProvider ?? activeProvider()
        let (resolved, reason) = resolveProviderForTask(
            preferred: preferred,
            prompt: prompt,
            history: history,
            instructions: instructions
        )
        if let reason = reason {
            print("🧠 [ModelRegistry] \(reason)")
        }

        switch resolved {
        case .localOllama:
            return OllamaAgentEngine(orchestrator: orchestrator, bot: bot)
        case .localMLX:
            return MLXAgentEngine(orchestrator: orchestrator)
        case .appleOnDevice, .applePCC, .fmCLI, .cloudGemini:
            return NativeAppleEngine(orchestrator: orchestrator)
        }
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
        case .appleOnDevice:
            return SystemLanguageModel.default
        case .applePCC:
            return PrivateCloudComputeLanguageModel()
        case .cloudGemini:
            return CloudGeminiLanguageModel(apiKey: apiKey ?? geminiAPIKey())
        case .localOllama:
            return LocalOllamaLanguageModel(hostURL: URL(string: "http://localhost:11434")!)
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

    /// Convenience: build the automatic fallback chain as an ordered list.
    public static func automaticChain() -> [any LanguageModel] {
        [
            SystemLanguageModel.default,
            PrivateCloudComputeLanguageModel(),
            CloudGeminiLanguageModel(apiKey: geminiAPIKey()),
            LocalOllamaLanguageModel(hostURL: URL(string: "http://localhost:11434")!),
            LocalMLXLanguageModel(hostURL: mlxHost()),
        ]
    }
}
