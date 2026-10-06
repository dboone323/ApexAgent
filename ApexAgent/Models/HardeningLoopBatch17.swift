import Foundation

// MARK: - Hardening Loop Batch 17: Model Tier, Privacy & Strategy Reporting
//
// 10 additive badges/formatters/validators. Pure functions only.

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
        }
    }

    public var isLocal: Bool {
        switch self {
        case .appleOnDevice, .localOllama, .localMLX, .fmCLI: return true
        case .autoPicker, .applePCC, .cloudGemini: return false
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
