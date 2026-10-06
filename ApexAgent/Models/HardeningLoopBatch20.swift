import Foundation

// MARK: - Hardening Loop Batch 20: Demo, TTS & Session-State Reporting
//
// 10 additive formatters/validators. Pure functions only. No behavior changes.

extension DemoRecorder.ActionKind {
    public var badge: String {
        switch self {
        case .mouseClick: return "🖱️ Click"
        case .keyStroke: return "⌨️ Keystroke"
        case .appSwitch: return "🔄 App Switch"
        case .customStep: return "📝 Custom Step"
        }
    }

    public var appName: String {
        switch self {
        case .mouseClick(_, _, _, let app, _, _): return app
        case .keyStroke(_, _, let app): return app
        case .appSwitch(let app, _): return app
        case .customStep: return ""
        }
    }
}

extension DemoRecorder.RecordedAction {
    public func formatAsMarkdown() -> String {
        "| `\(timestamp)` | \(kind.badge) | \(String(description.prefix(160)).replacingOccurrences(of: "|", with: "\\|")) |"
    }

    public var isWellFormed: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension TTSProvider {
    public var badge: String {
        switch self {
        case .system: return "🔊 System TTS"
        case .elevenLabs: return "🎙️ ElevenLabs"
        }
    }

    public var requiresNetwork: Bool {
        switch self {
        case .system: return false
        case .elevenLabs: return true
        }
    }
}

extension VoiceController {
    /// Snapshot summary that never touches the audio engine.
    public func stateSummaryMarkdown() -> String {
        var md = "### 🎙️ Voice Controller State\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Recording | \(isRecording ? "🔴 Active" : "⚪️ Idle") |\n"
        md += "| Speaking | \(isSpeaking ? "🔊 Active" : "⚪️ Idle") |\n"
        md += "| Provider | \(selectedProvider.badge) |\n"
        md += "| Permission | \(permissionGranted ? "✅ Granted" : "⚪️ Not Granted") |\n"
        return md
    }
}

extension GroupChatSession {
    /// Turn-progress snapshot without starting or mutating generation.
    public func turnProgressMarkdown() -> String {
        let total = generationOrder.count
        var md = "### 👥 Group Chat `\(name)`: \(currentTurnIndex)/\(total) turns\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Participants | `\(participants.count)` |\n"
        md += "| Generating | \(isGenerating ? "⚡️ Active" : "💤 Idle") |\n"
        md += "| Tool Calls | \(toolCallsEnabled ? "🟢 Enabled" : "⚪️ Disabled") (`\(toolExecutionLog.count)` logged) |\n"
        return md
    }
}
