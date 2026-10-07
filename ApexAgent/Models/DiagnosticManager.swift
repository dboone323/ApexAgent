import Foundation
import ApplicationServices
import CoreGraphics

struct DiagnosticItem: Identifiable, Codable {
    var id: String { name }
    let name: String
    let category: String
    let status: DiagnosticStatus
    let message: String
}

public enum DiagnosticStatus: String, Codable, Sendable {
    case pass = "Pass"
    case warning = "Warning"
    case fail = "Fail"
}

struct DiagnosticManager {
    @MainActor
    static func runSelfCheck(provider: OrchestratorProvider? = nil) async -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []

        let orchestrator = provider?.orchestrator ?? MCPManager.shared.orchestrator
        let isRestricted = orchestrator.isFolderAccessRestricted()

        // Use bounded checks so a hung tool cannot block diagnostics forever.
        async let xcodeCheck = checkCommandExists("xcode-select -p", isFolderAccessRestricted: isRestricted)
        async let brewCheck = checkCommandExists("which brew", isFolderAccessRestricted: isRestricted)
        async let nodeCheck = checkCommandExists("which node", isFolderAccessRestricted: isRestricted)
        async let pythonCheck = checkCommandExists("which python3", isFolderAccessRestricted: isRestricted)
        async let gitCheck = checkCommandExists("which git", isFolderAccessRestricted: isRestricted)

        let (hasXcodeSelect, hasBrew, hasNode, hasPython, hasGit) = await (xcodeCheck, brewCheck, nodeCheck, pythonCheck, gitCheck)

        items.append(DiagnosticItem(name: "Xcode Command Line Tools", category: "CLI Tools", status: hasXcodeSelect ? .pass : .fail, message: hasXcodeSelect ? "Installed successfully." : "Missing. Run 'xcode-select --install' in Terminal."))
        items.append(DiagnosticItem(name: "Homebrew", category: "CLI Tools", status: hasBrew ? .pass : .warning, message: hasBrew ? "Homebrew is available." : "Missing. Install from brew.sh to easily manage dependencies."))
        items.append(DiagnosticItem(name: "Node.js", category: "CLI Tools", status: hasNode ? .pass : .warning, message: hasNode ? "Node.js is available." : "Missing. Required for running JavaScript tasks or packages."))
        items.append(DiagnosticItem(name: "Python 3", category: "CLI Tools", status: hasPython ? .pass : .warning, message: hasPython ? "Python 3 is available." : "Missing. Highly recommended for AI scripts and local tooling."))
        items.append(DiagnosticItem(name: "Git", category: "CLI Tools", status: hasGit ? .pass : .fail, message: hasGit ? "Git is available." : "Missing. Git is required to manage source code changes."))

        let isAccessibilityTrusted = AXIsProcessTrusted()
        let isAccessibilityAllowedInSettings = orchestrator.permissions?.accessibilityAllowed ?? false
        items.append(DiagnosticItem(
            name: "Accessibility Entitlement",
            category: "System Permissions",
            status: isAccessibilityAllowedInSettings ? (isAccessibilityTrusted ? .pass : .warning) : .pass,
            message: isAccessibilityAllowedInSettings
                ? (isAccessibilityTrusted ? "Granted." : "Not granted. Enable in System Settings ➔ Privacy & Security ➔ Accessibility.")
                : "Disabled in Settings."
        ))

        let screenAccess = checkScreenRecordingAccess()
        let isScreenAllowedInSettings = orchestrator.permissions?.screenRecordingAllowed ?? false
        items.append(DiagnosticItem(
            name: "Screen Recording Entitlement",
            category: "System Permissions",
            status: isScreenAllowedInSettings ? (screenAccess ? .pass : .warning) : .pass,
            message: isScreenAllowedInSettings
                ? (screenAccess ? "Granted." : "Not granted. Enable in System Settings ➔ Privacy & Security ➔ Screen Recording.")
                : "Disabled in Settings."
        ))

        let fm = FileManager.default
        let toolsDir = ApexAgentStoragePaths.tools
        let hasToolsDir = fm.fileExists(atPath: toolsDir.path)

        items.append(DiagnosticItem(
            name: "Custom Tools Directory (~/.apex/tools)",
            category: "Agent Configuration",
            status: hasToolsDir ? .pass : .warning,
            message: hasToolsDir ? "Directory exists." : "Missing tools directory. Will be created on dynamic watch start."
        ))

        if hasToolsDir {
            let activeTools = DynamicToolbox.shared.dynamicTools
            var unhealthyToolsCount = 0
            var unhealthyDetails = ""

            for (name, entry) in activeTools {
                if let scriptPath = entry.scriptPath {
                    let resolvedScript = (scriptPath as NSString).expandingTildeInPath
                    if !fm.fileExists(atPath: resolvedScript) {
                        unhealthyToolsCount += 1
                        unhealthyDetails += "\n• Tool '\(name)' script is missing at '\(scriptPath)'"
                    }
                }
            }

            items.append(DiagnosticItem(
                name: "Custom Dynamic Tools Status",
                category: "Agent Configuration",
                status: unhealthyToolsCount == 0 ? .pass : (unhealthyToolsCount == activeTools.count ? .fail : .warning),
                message: unhealthyToolsCount == 0 ? "All \(activeTools.count) dynamic tool(s) are healthy." : "Found \(unhealthyToolsCount)/\(activeTools.count) dynamic tool(s) with missing executable scripts.\(unhealthyDetails)"
            ))
        }

        return items
    }

    @MainActor
    static func exportReport(_ items: [DiagnosticItem]) -> String {
        struct DiagnosticReport: Codable {
            let generatedAt: String
            let items: [DiagnosticItem]
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let report = DiagnosticReport(generatedAt: ISO8601DateFormatter().string(from: Date()), items: items)
        let data = (try? encoder.encode(report)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    @MainActor
    static func exportMarkdownReport(_ items: [DiagnosticItem]) -> String {
        var md = "### 🩺 ApexAgent System Diagnostics Report\n\n"
        md += "| Category | Item | Status | Details |\n"
        md += "|---|---|---|---|\n"

        for item in items {
            let statusBadge: String
            switch item.status {
            case .pass: statusBadge = "✅ Pass"
            case .warning: statusBadge = "⚠️ Warning"
            case .fail: statusBadge = "❌ Fail"
            }
            let safeMsg = item.message.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            md += "| \(item.category) | **\(item.name)** | \(statusBadge) | \(safeMsg) |\n"
        }
        return md
    }

    private static func checkCommandExists(_ command: String, isFolderAccessRestricted: Bool) async -> Bool {
        let binaryName = command.components(separatedBy: " ").last ?? command
        let fm = FileManager.default
        let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if command.hasPrefix("xcode-select") {
            return fm.fileExists(atPath: "/Applications/Xcode-beta.app")
                || fm.fileExists(atPath: "/Applications/Xcode.app")
                || fm.fileExists(atPath: "/Library/Developer/CommandLineTools")
                || fm.isExecutableFile(atPath: "/usr/bin/xcode-select")
        }
        for dir in searchPaths {
            let fullPath = (dir as NSString).appendingPathComponent(binaryName)
            if fm.isExecutableFile(atPath: fullPath) {
                return true
            }
        }
        return false
    }

    private static func checkScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}

extension DiagnosticStatus {
    public var badge: String {
        switch self {
        case .pass: return "✅ Pass"
        case .warning: return "⚠️ Warning"
        case .fail: return "❌ Fail"
        }
    }
}

extension DiagnosticItem {
    public func formatAsMarkdown() -> String {
        "| **\(name)** | `\(category)` | \(status.badge) | \(message.prefix(200)) |"
    }

    public static func summarizeAsMarkdown(_ items: [DiagnosticItem]) -> String {
        guard !items.isEmpty else { return "No diagnostic results recorded." }
        let fails = items.filter { $0.status == .fail }.count
        let warns = items.filter { $0.status == .warning }.count
        var md = "### 🩺 Diagnostics Summary: \(items.count) checks (\(fails) failing, \(warns) warnings)\n\n"
        md += "| Check | Category | Status | Message |\n"
        md += "|---|---|---|---|\n"
        for item in items { md += item.formatAsMarkdown() + "\n" }
        return md
    }
}
