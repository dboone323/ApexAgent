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

enum DiagnosticStatus: String, Codable {
    case pass = "Pass"
    case warning = "Warning"
    case fail = "Fail"
}

struct DiagnosticManager {
    @MainActor
    static func runSelfCheck() -> [DiagnosticItem] {
        var items: [DiagnosticItem] = []
        
        // 1. Check Xcode CLI Tools
        let hasXcodeSelect = checkCommandExists("xcode-select -p")
        items.append(DiagnosticItem(
            name: "Xcode Command Line Tools",
            category: "CLI Tools",
            status: hasXcodeSelect ? .pass : .fail,
            message: hasXcodeSelect ? "Installed successfully." : "Missing. Run 'xcode-select --install' in Terminal."
        ))
        
        // 2. Check Homebrew
        let hasBrew = checkCommandExists("which brew")
        items.append(DiagnosticItem(
            name: "Homebrew",
            category: "CLI Tools",
            status: hasBrew ? .pass : .warning,
            message: hasBrew ? "Homebrew is available." : "Missing. Install from brew.sh to easily manage dependencies."
        ))
        
        // 3. Check Node.js
        let hasNode = checkCommandExists("which node")
        items.append(DiagnosticItem(
            name: "Node.js",
            category: "CLI Tools",
            status: hasNode ? .pass : .warning,
            message: hasNode ? "Node.js is available." : "Missing. Required for running JavaScript tasks or packages."
        ))
        
        // 4. Check Python 3
        let hasPython = checkCommandExists("which python3")
        items.append(DiagnosticItem(
            name: "Python 3",
            category: "CLI Tools",
            status: hasPython ? .pass : .warning,
            message: hasPython ? "Python 3 is available." : "Missing. Highly recommended for AI scripts and local tooling."
        ))
        
        // 5. Check Git
        let hasGit = checkCommandExists("which git")
        items.append(DiagnosticItem(
            name: "Git",
            category: "CLI Tools",
            status: hasGit ? .pass : .fail,
            message: hasGit ? "Git is available." : "Missing. Git is required to manage source code changes."
        ))
        
        // 6. Check Accessibility Permissions
        let isAccessibilityTrusted = AXIsProcessTrusted()
        let isAccessibilityAllowedInSettings = AgentOrchestrator.shared?.permissions?.accessibilityAllowed ?? false
        items.append(DiagnosticItem(
            name: "Accessibility Entitlement",
            category: "System Permissions",
            status: isAccessibilityAllowedInSettings ? (isAccessibilityTrusted ? .pass : .warning) : .pass,
            message: isAccessibilityAllowedInSettings
                ? (isAccessibilityTrusted ? "Granted." : "Not granted. Enable in System Settings ➔ Privacy & Security ➔ Accessibility.")
                : "Disabled in Settings."
        ))
        
        // 7. Check Screen Recording Permissions
        let screenAccess = checkScreenRecordingAccess()
        let isScreenAllowedInSettings = AgentOrchestrator.shared?.permissions?.screenRecordingAllowed ?? false
        items.append(DiagnosticItem(
            name: "Screen Recording Entitlement",
            category: "System Permissions",
            status: isScreenAllowedInSettings ? (screenAccess ? .pass : .warning) : .pass,
            message: isScreenAllowedInSettings
                ? (screenAccess ? "Granted." : "Not granted. Enable in System Settings ➔ Privacy & Security ➔ Screen Recording.")
                : "Disabled in Settings."
        ))
        
        // 8. Check Custom Tools & Skills
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let toolsDir = homeDir.appendingPathComponent(".apex/tools")
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
    private static func checkCommandExists(_ command: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath
        
        if AgentOrchestrator.isFolderAccessRestricted() {
            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser
            let sandboxDir = homeDir.appendingPathComponent(".apex/sandbox")
            try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
            env["HOME"] = sandboxDir.path
        }
        
        process.environment = env
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    private static func checkScreenRecordingAccess() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
}
