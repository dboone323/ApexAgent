import Foundation

// MARK: - Hardening Loop Batch 11: Markdown Diagnostics Gap Closure
//
// 10 additive, dependency-free markdown exporters for models that lacked
// a markdown projection. All pure functions over existing public/internal
// state. No behavior changes, no mocks.

extension A2AAgentCard {
    public func formatAsMarkdown() -> String {
        var md = "### 📡 A2A Agent Card: \(name)\n\n"
        md += "- **Description**: \(description)\n"
        md += "- **Version**: `\(version)`\n"
        md += "- **Endpoint**: `\(url)`\n"
        md += "- **Capabilities**: streaming=\(capabilities.streaming ? "✅" : "⚪️"), push=\(capabilities.pushNotifications ? "✅" : "⚪️"), history=\(capabilities.stateTransitionHistory ? "✅" : "⚪️")\n"
        md += "- **Default Modes**: in=[\(defaultInputModes.joined(separator: ", "))], out=[\(defaultOutputModes.joined(separator: ", "))]\n"
        if skills.isEmpty {
            md += "\nNo skills advertised.\n"
        } else {
            md += "\n| Skill ID | Name | Description | Tags |\n"
            md += "|---|---|---|---|\n"
            for s in skills {
                let safeDesc = s.description.replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(s.id)` | **\(s.name)** | \(safeDesc) | \(s.tags.joined(separator: ", ")) |\n"
            }
        }
        return md
    }
}

extension A2AResponse {
    public func formatAsMarkdown() -> String {
        var md = "### 📨 A2A JSON-RPC Response: `\(id)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| JSON-RPC | `\(jsonrpc)` |\n"
        if let result {
            md += "| Task ID | `\(result.id)` |\n"
            md += "| State | `\(result.status.state)` |\n"
            md += "| Artifacts | `\(result.artifacts.count)` |\n"
            for (i, art) in result.artifacts.enumerated() {
                let text = art.parts.compactMap { $0.text }.joined(separator: " / ").prefix(160)
                md += "| Artifact \(i + 1) | \(text) |\n"
            }
        }
        if let error {
            md += "| Error | `\(error.code)` \(error.message.replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }
}

extension AgentEvaluationScorecard {
    public func formatAsMarkdown() -> String {
        var md = "### 📊 Agent Capability Scorecard — \(String(format: "%.1f", overallScore)) (\(grade.rawValue))\n\n"
        md += "| Dimension | Score | Checks | Notes |\n"
        md += "|---|---|---|---|\n"
        for ds in dimensionScores {
            let safeNotes = ds.notes.replacingOccurrences(of: "|", with: "\\|")
            md += "| **\(ds.dimension.rawValue)** | `\(String(format: "%.1f%%", ds.score))` | `\(ds.passedChecks)/\(ds.totalChecks)` | \(safeNotes) |\n"
        }
        md += "| **Overall** | **`\(String(format: "%.1f", overallScore))`** | pass@1=`\(benchmarkPassAt1)` pass@5=`\(benchmarkPassAt5)` | **\(grade.rawValue)** |\n"
        if !recommendations.isEmpty {
            md += "\n**Recommendations**:\n"
            for r in recommendations { md += "- \(r.replacingOccurrences(of: "|", with: "\\|"))\n" }
        }
        return md
    }
}

extension RegisteredAgent {
    public func formatAsMarkdown() -> String {
        var md = "### 🤖 Registered Agent: `\(name)`\n\n"
        let promptPreview = String(systemPrompt.prefix(160)).replacingOccurrences(of: "|", with: "\\|")
        md += "| Property | Value |\n"
        md += "|---|---|\n"
        md += "| Name | `\(name)` |\n"
        md += "| Model Preference | `\(modelPreference ?? "default")` |\n"
        md += "| Allowed Tools | `\(allowedTools.count)` (\(allowedTools.prefix(8).joined(separator: ", "))\(allowedTools.count > 8 ? "…" : "")) |\n"
        md += "| System Prompt | \(promptPreview) |\n"
        return md
    }
}

extension WebhookPayload {
    func summaryMarkdown() -> String {
        var md = "### 🪝 Webhook Payload\n\n"
        switch self {
        case .json(let dict):
            md += "| Key | Value |\n|---|---|\n"
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                md += "| `\(k)` | \(v.prefix(120)) |\n"
            }
        case .form(let dict):
            md += "| Field | Value |\n|---|---|\n"
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                md += "| `\(k)` | \(v.prefix(120)) |\n"
            }
        case .text(let t):
            md += "\(t.prefix(300))\n"
        case .empty:
            md += "Empty payload.\n"
        }
        return md
    }
}

extension ComputerUseStep {
    public func formatAsMarkdown() -> String {
        var md = "### 🖱️ Computer-Use Step \(turn): \(action.humanReadableSummary)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Turn | `\(turn)` |\n"
        md += "| Action | \(action.humanReadableSummary) |\n"
        md += "| Observation | \(observation.prefix(200)) |\n"
        return md
    }
}

extension WeeklyReflection {
    public func formatAsMarkdown() -> String {
        var md = "### 📝 Weekly Reflection — \(weekStartDate)\n\n"
        md += "\(text.prefix(500))\n"
        return md
    }
}

extension SkillManifestInfo {
    public func formatAsMarkdown() -> String {
        var md = "### 🛠️ Skill Manifest: `\(name)`\n\n"
        md += "| Property | Value |\n"
        md += "|---|---|\n"
        md += "| Name | `\(name)` |\n"
        md += "| Description | \(description.prefix(200)) |\n"
        md += "| Script | `\(scriptPath)` |\n"
        md += "| Parameters | `\(parameterCount)` |\n"
        return md
    }
}

extension CronSchedule {
    public func formatScheduleSummaryMarkdown() -> String {
        var md = "### ⏱️ Cron Schedule: `\(rawExpression)` (\(humanReadableDescription))\n\n"
        md += "| Field | Values |\n"
        md += "|---|---|\n"
        md += "| Minutes | `\(minutes.sorted().prefix(12).map(String.init).joined(separator: ","))\(minutes.count > 12 ? "…" : "")` |\n"
        md += "| Hours | `\(hours.sorted().map(String.init).joined(separator: ","))` |\n"
        md += "| Days of Month | `\(daysOfMonth.sorted().prefix(12).map(String.init).joined(separator: ","))\(daysOfMonth.count > 12 ? "…" : "")` |\n"
        md += "| Months | `\(months.sorted().map(String.init).joined(separator: ","))` |\n"
        md += "| Days of Week | `\(daysOfWeek.sorted().map(String.init).joined(separator: ","))` |\n"
        return md
    }
}

extension ProactiveScheduler.ProactiveFinding {
    public func formatAsMarkdown() -> String {
        let badge: String
        switch severity {
        case .critical: badge = "🛑 Critical"
        case .warning: badge = "⚠️ Warning"
        case .info: badge = "ℹ️ Info"
        }
        var md = "### ⚡️ Proactive Finding: \(title)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Severity | \(badge) |\n"
        md += "| Target Bot | `\(targetBotName ?? "system")` |\n"
        md += "| Detail | \(detail.prefix(300)) |\n"
        return md
    }
}
