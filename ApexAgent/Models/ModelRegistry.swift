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
    case cloudGemini
    case localOllama
    case localMLX
    case fmCLI

    public var displayName: String {
        switch self {
        case .appleOnDevice: "Apple On-Device"
        case .applePCC: "Apple Private Cloud Compute"
        case .cloudGemini: "Cloud Gemini"
        case .localOllama: "Local Ollama"
        case .localMLX: "Local MLX"
        case .fmCLI: "fm CLI (Apple)"
        }
    }
}

public enum ModelSelectionStrategy: Sendable {
    /// Use exactly the requested provider.
    case explicit(ModelProvider)
    /// Replicate the legacy fallback chain used by the tools:
    /// on-device → PCC → Gemini → Ollama → MLX.
    case automatic
}

public struct ModelRegistry {

    /// Keys mirrored from the existing tool implementations.
    private static let geminiKeyKey = "apex.geminiKey"
    private static let ollamaModelKey = "apex.ollamaModel"
    private static let mlxHostKey = "apex.mlxHost"
    public static let providerKey = "apex.modelProvider"

    private static func geminiAPIKey() -> String {
        UserDefaults.standard.string(forKey: geminiKeyKey) ?? ""
    }

    private static func ollamaModel() -> String {
        UserDefaults.standard.string(forKey: ollamaModelKey) ?? "qwen2.5-coder:latest"
    }

    private static func mlxHost() -> URL {
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

    /// Build a `LanguageModel` for the given strategy.
    ///
    /// - Note: `localMLX` is known to SIGSEGV on the current macOS 27 beta build
    ///   (beta skew in the MLX-LM server bridge). It is included for API
    ///   completeness; callers should not select it on this beta.
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

    /// Convenience: build the automatic fallback chain as an ordered list so a
    /// caller can try providers in sequence and fall back on failure.
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
