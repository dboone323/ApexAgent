import Foundation
import AppKit
import Observation
import SharedKit

// MARK: - Computer: The local Mac as the shared execution environment

/// The "computer" abstraction — here this is a persistent cloud VM with
/// browser, filesystem, and terminal. In ApexAgent v1, the computer is the
/// local Mac itself. All Bots share it; each Bot gets its own screen (chat
/// session) on that computer.
///
/// This type formalizes the interfaces Bots use to interact with the Mac.
/// It is not a separate process — it is a structured facade over AppKit/Foundation.
@Observable
@MainActor
final class Computer {
    /// The shared workspace directory where Bots can persist project files.
    /// Resembles the agent's `/workspace` on the cloud VM.
    static var sharedWorkspaceURL: URL {
        let ws = ApexAgentStoragePaths.directory("computer-workspace")
        try? FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return ws
    }

    /// Whether the computer is currently showing a screen takeover (user is
    /// controlling the Bot's browser/terminal session directly).
    var isTakeoverActive: Bool = false

    /// The conversation ID this computer view is attached to (for screen sharing).
    var activeTakeoverConversationId: UUID?

    // MARK: - Browser Interface

    /// Opens a URL in the default browser (or a dedicated browser profile for a Bot).
    /// On macOS this uses NSWorkspace — in a future cloud-VM mode this would drive
    /// a headless browser on the VM.
    func openURL(_ url: URL) -> String {
        NSWorkspace.shared.open(url)
        return "Opened \(url.absoluteString) in the default browser."
    }

    /// Returns the current frontmost application — useful for Bots that need to
    /// know what the user is doing or whether a site is visible.
    func getCurrentApplication() -> String {
        let frontmost = NSRunningApplication.current
        let name = frontmost.localizedName ?? "Unknown"
        return "Frontmost application: \(name) (bundle: \(frontmost.bundleIdentifier ?? "none"))"
    }

    /// Lists recently active applications (a simplified "running processes" view).
    func listApplications(limit: Int = 20) -> String {
        let apps = NSWorkspace.shared.runningApplications
            .prefix(limit)
            .compactMap { app -> String? in
                let name = app.localizedName ?? "Unknown"
                let bundle = app.bundleIdentifier ?? "none"
                return "\(name) (\(bundle))"
            }
            .joined(separator: "\n")
        return "Running applications (top \(limit)):\n\(apps)"
    }

    // MARK: - Filesystem Interface

    /// Reads a file from the shared workspace or an allowed path.
    func readFile(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return "ERROR: File not found: \(expanded)"
        }
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else {
            return "ERROR: Could not read as text: \(expanded)"
        }
        return content
    }

    /// Writes content to a file in the shared workspace or an allowed path.
    func writeFile(path: String, content: String, append: Bool = false) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if append, FileManager.default.fileExists(atPath: expanded) {
            let existing = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? ""
            let combined = existing + content
            try? combined.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        return "Wrote \(content.count) bytes to \(expanded)."
    }

    /// Lists files in a directory.
    func listDirectory(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let urls = try? FileManager.default.contentsOfDirectory(atPath: expanded) else {
            return "ERROR: Cannot list directory: \(expanded)"
        }
        let items = urls.map { "\($0)" }.joined(separator: "\n")
        return "Contents of \(expanded):\n\(items)"
    }

    /// Creates a directory.
    func createDirectory(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: expanded, withIntermediateDirectories: true)
        return "Created directory: \(expanded)"
    }

    /// Moves/renames a file.
    func moveFile(from source: String, to destination: String) -> String {
        let src = NSString(string: source).expandingTildeInPath
        let dst = NSString(string: destination).expandingTildeInPath
        try? FileManager.default.moveItem(atPath: src, toPath: dst)
        return "Moved \(src) → \(dst)."
    }

    /// Deletes a file.
    func deleteFile(path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        try? FileManager.default.removeItem(atPath: expanded)
        return "Deleted: \(expanded)."
    }

    // MARK: - Terminal Interface

    /// Runs a shell command on the local Mac.
    /// This is the Computer's terminal — here this runs on the cloud VM.
    func runShellCommand(_ command: String, workspace: String? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let ws = workspace {
            process.currentDirectoryURL = URL(fileURLWithPath: ws)
        } else {
            process.currentDirectoryURL = Computer.sharedWorkspaceURL
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            let outHandle = out.fileHandleForReading
            let errHandle = err.fileHandleForReading
            final class PipeCapture: @unchecked Sendable {
                var data = Data()
            }
            let outCapture = PipeCapture()
            let errCapture = PipeCapture()
            let t1 = Thread {
                outCapture.data = outHandle.readDataToEndOfFile()
            }
            let t2 = Thread {
                errCapture.data = errHandle.readDataToEndOfFile()
            }
            t1.start()
            t2.start()
            process.waitUntilExit()
            while !t1.isFinished || !t2.isFinished {
                Thread.sleep(forTimeInterval: 0.005)
            }
            let stdout = String(data: outCapture.data, encoding: .utf8) ?? ""
            let stderr = String(data: errCapture.data, encoding: .utf8) ?? ""
            let combined = stdout + stderr
            let truncated = combined.count > 50000 ? String(combined.prefix(50000)) + "\n[... output truncated ...]" : combined
            return "Exit code: \(process.terminationStatus)\n\n\(truncated)"
        } catch {
            return "ERROR: Failed to run command: \(error.localizedDescription)"
        }
    }

    // MARK: - Takeover Interface

    /// Signals that the user is taking over the computer for a sensitive step
    /// (password, 2FA, CAPTCHA, etc.). The UI should show the Agent Computer view
    /// and let the user complete the step, then return control.
    func startTakeover(for conversationId: UUID) {
        isTakeoverActive = true
        activeTakeoverConversationId = conversationId
    }

    /// Ends the takeover — the Bot resumes control.
    func endTakeover() {
        isTakeoverActive = false
        activeTakeoverConversationId = nil
    }

    // MARK: - Markdown Summaries

    func listApplicationsMarkdown(limit: Int = 20) -> String {
        let apps = Array(NSWorkspace.shared.runningApplications.prefix(limit))
        guard !apps.isEmpty else {
            return "No running applications detected."
        }

        var md = "### 🖥️ Running Applications (\(apps.count) shown)\n\n"
        md += "| Application Name | Bundle Identifier | Process ID |\n"
        md += "|---|---|---|\n"

        for app in apps {
            let name = app.localizedName ?? "Unknown"
            let bundle = app.bundleIdentifier ?? "none"
            md += "| **\(name)** | `\(bundle)` | `\(app.processIdentifier)` |\n"
        }
        return md
    }

    func workspaceSummaryMarkdown() -> String {
        let ws = Computer.sharedWorkspaceURL
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: ws.path) else {
            return "Shared workspace is empty or inaccessible at `\(ws.path)`."
        }

        var md = "### 📁 Computer Shared Workspace: `\(ws.path)`\n\n"
        md += "| File / Subdirectory | Size / Type |\n"
        md += "|---|---|\n"

        for f in files.prefix(30) {
            let fullPath = ws.appendingPathComponent(f).path
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
            let typeBadge = isDir.boolValue ? "📁 Directory" : "📄 File"
            md += "| `\(f)` | \(typeBadge) |\n"
        }
        return md
    }

}