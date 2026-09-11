import Foundation
import Synchronization

// MARK: - WS3: LaunchAgent supervision so bots keep working with the app closed
//
// Grok Bot's defining capability is 24/7 bots. ApexAgent's equivalent is the
// `--daemon` mode (gateway + bots + routines + webhook receiver) supervised by
// a per-user launchd agent: it starts at login, restarts on crash, and keeps
// scheduled/webhook routines alive when the GUI is not running.
//
// Plist generation is pure and unit-tested; install/uninstall write into an
// injectable directory (defaults to ~/Library/LaunchAgents) and shell out to
// `launchctl bootout/bootstrap` only through explicit calls.

struct LaunchAgentConfig {
    /// Reverse-DNS label, e.g. "com.apexagent.daemon".
    let label: String
    let programPath: String
    let arguments: [String]
    var runAtLoad: Bool = true
    var keepAlive: Bool = true
}

enum LaunchAgentPlist {
    static func xml(for config: LaunchAgentConfig) -> String {
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

    static func stdoutPath(for config: LaunchAgentConfig) -> String {
        "\(NSHomeDirectory())/Library/Logs/\(config.label).out.log"
    }

    static func stderrPath(for config: LaunchAgentConfig) -> String {
        "\(NSHomeDirectory())/Library/Logs/\(config.label).err.log"
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
