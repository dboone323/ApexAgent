import Foundation
import Synchronization

// MARK: - WS3: LaunchAgent supervision so bots keep working with the app closed
//
// A defining capability is 24/7 bots. ApexAgent's equivalent is the
// `--daemon` mode (gateway + bots + routines + webhook receiver) supervised by
// a per-user launchd agent: it starts at login, restarts on crash, and keeps
// scheduled/webhook routines alive when the GUI is not running.
//
// Plist generation is pure and unit-tested; install/uninstall write into an
// injectable directory (defaults to ~/Library/LaunchAgents) and shell out to
// `launchctl bootout/bootstrap` only through explicit calls.

public struct LaunchAgentConfig: Sendable, Codable, Equatable {
    /// Reverse-DNS label, e.g. "com.apexagent.daemon".
    public let label: String
    public let programPath: String
    public let arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: Bool

    public init(
        label: String,
        programPath: String,
        arguments: [String],
        runAtLoad: Bool = true,
        keepAlive: Bool = true
    ) {
        self.label = label
        self.programPath = programPath
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
    }
}

public enum LaunchAgentPlist {
    public static func xml(for config: LaunchAgentConfig) -> String {
        let args = ([config.programPath] + config.arguments)
            .map { "<string>\(escaped($0))</string>" }
            .joined(separator: "\n        ")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escaped(config.label))</string>
            <key>ProgramArguments</key>
            <array>
                \(args)
            </array>
            <key>RunAtLoad</key>
            <\(config.runAtLoad ? "true" : "false")/>
            <key>KeepAlive</key>
            <\(config.keepAlive ? "true" : "false")/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(escaped(stdoutPath(for: config)))</string>
            <key>StandardErrorPath</key>
            <string>\(escaped(stderrPath(for: config)))</string>
        </dict>
        </plist>
        """
    }

    public static func stdoutPath(for config: LaunchAgentConfig) -> String {
        "\(NSHomeDirectory())/Library/Logs/\(config.label).out.log"
    }

    public static func stderrPath(for config: LaunchAgentConfig) -> String {
        "\(NSHomeDirectory())/Library/Logs/\(config.label).err.log"
    }

    // MARK: - Markdown Configuration Summary

    static func formatConfigMarkdown(_ config: LaunchAgentConfig) -> String {
        var md = "### 🚀 macOS launchd Agent Daemon Configuration\n\n"
        md += "| Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Reverse-DNS Label | `\(config.label)` | System service identifier |\n"
        md += "| Target Program | `\(config.programPath)` | Executable binary |\n"
        let argsJoined = config.arguments.joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
        md += "| Arguments | `\(argsJoined)` | Startup parameters |\n"
        md += "| Run At Load | \(config.runAtLoad ? "✅ Enabled" : "❌ Disabled") | Launch on user login |\n"
        md += "| Keep Alive | \(config.keepAlive ? "✅ Enabled" : "❌ Disabled") | Auto-restart on crash |\n"
        md += "| Standard Out Log | `\(stdoutPath(for: config))` | Stdout redirect destination |\n"
        md += "| Standard Error Log | `\(stderrPath(for: config))` | Stderr redirect destination |\n"
        return md
    }

    private static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Installs/uninstalls the daemon LaunchAgent. The agents directory is
/// injectable so tests never touch the user's real LaunchAgents folder.
final class LaunchAgentController {

    static let defaultLabel = "com.apexagent.daemon"
    static var defaultArguments: [String] { ["--daemon"] }

    /// Injectable for tests; defaults to the real per-user LaunchAgents dir.
    private static let _agentsDirectory = Mutex<URL>(
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    )

    static var agentsDirectory: URL {
        get {
            _agentsDirectory.withLock { $0 }
        }
        set {
            _agentsDirectory.withLock { $0 = newValue }
        }
    }

    private let label: String

    init(label: String = LaunchAgentController.defaultLabel) {
        self.label = label
    }

    var plistURL: URL {
        Self.agentsDirectory.appendingPathComponent("\(label).plist")
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Write the plist (creating the directory), returning its path.
    @discardableResult
    func install(programPath: String,
                 arguments: [String] = LaunchAgentController.defaultArguments,
                 runAtLoad: Bool = true,
                 keepAlive: Bool = true) throws -> URL {
        let config = LaunchAgentConfig(
            label: label,
            programPath: programPath,
            arguments: arguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive)
        try FileManager.default.createDirectory(
            at: Self.agentsDirectory, withIntermediateDirectories: true)
        try LaunchAgentPlist.xml(for: config)
            .write(to: plistURL, atomically: true, encoding: .utf8)
        return plistURL
    }

    func uninstall() throws {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    // MARK: launchctl (explicit, never called from tests)

    private var guiDomain: String {
        "gui/\(getuid())"
    }

    /// Load + start the agent now. Returns false if launchctl rejected it.
    @discardableResult
    func bootstrapNow() -> Bool {
        runLaunchctl(["bootstrap", guiDomain, plistURL.path])
    }

    /// Stop and unload the agent.
    @discardableResult
    func bootoutNow() -> Bool {
        runLaunchctl(["bootout", "\(guiDomain)/\(label)"])
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

extension LaunchAgentConfig {
    public func validationError() -> String? {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLabel.isEmpty { return "Label must not be empty." }
        let parts = trimmedLabel.split(separator: ".")
        if parts.count < 2 { return "Label should be reverse-DNS (e.g. com.apexagent.daemon)." }
        if programPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "programPath must not be empty."
        }
        return nil
    }

    public var isValid: Bool { validationError() == nil }

    public func formatAsMarkdown() -> String {
        var md = "### 🚀 LaunchAgent: `\(label)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Program | `\(programPath)` |\n"
        md += "| Arguments | `\(arguments.joined(separator: " "))` |\n"
        md += "| RunAtLoad | \(runAtLoad ? "✅" : "⚪️") |\n"
        md += "| KeepAlive | \(keepAlive ? "✅" : "⚪️") |\n"
        md += "| Valid | \(isValid ? "✅" : "❌ \(validationError() ?? "")") |\n"
        return md
    }
}
