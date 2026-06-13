import Foundation
import FoundationModels
import AppKit
import CoreGraphics

// MARK: - Screenshot Tool
// Uses the macOS `screencapture` CLI tool which works reliably on macOS 27
// and respects Screen Recording permissions.

struct ScreenshotTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "take_screenshot"
    let description = """
    Captures a screenshot of the entire screen and saves it to a PNG file. \
    Returns the file path of the saved screenshot. \
    Requires Screen Recording permission (System Settings → Privacy & Security → Screen Recording). \
    The saved file can then be opened or read as needed.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path to save the screenshot PNG. Defaults to ~/Desktop/apex_screenshot_<timestamp>.png")
        var savePath: String?

        @Guide(description: "If true, captures only the frontmost window instead of the full screen")
        var windowOnly: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let isScreenAllowed = DispatchQueue.main.sync {
                self.orchestrator.orchestrator.permissions?.screenRecordingAllowed ?? false
            }
            guard isScreenAllowed else {
                return "ERROR: Screen Recording check is disabled in Settings."
            }
            
            let isDesktopAllowed = DispatchQueue.main.sync {
                self.orchestrator.orchestrator.permissions?.desktopFolderAllowed ?? false
            }

            let timestamp = Int(Date().timeIntervalSince1970)
            let defaultPath: String
            if isDesktopAllowed {
                defaultPath = NSHomeDirectory() + "/Desktop/apex_screenshot_\(timestamp).png"
            } else {
                defaultPath = NSTemporaryDirectory() + "apex_screenshot_\(timestamp).png"
            }

            let savePath: String
            if let arg = arguments.savePath {
                let expanded = NSString(string: arg).expandingTildeInPath
                let isAllowed = await MainActor.run { self.orchestrator.orchestrator.isPathAllowed(expanded) }
                guard isAllowed else {
                    return "ERROR: Access to the specified path is disabled in settings: \(expanded)"
                }
                savePath = expanded
            } else {
                savePath = defaultPath
            }

            let windowOnly = arguments.windowOnly ?? false

            var windowID: UInt32? = nil
            if windowOnly {
                windowID = await MainActor.run {
                    return getFrontmostWindowID()
                }
            }

            // Build screencapture command
            // -x: no sound, -t png: PNG format
            // -o: no window shadow (cleaner)
            let command: String
            if windowOnly {
                guard let wId = windowID else {
                    return "ERROR: Could not detect active window ID of the frontmost application."
                }
                command = "/usr/sbin/screencapture -x -t png -o -l \(wId) \"\(savePath)\""
            } else {
                command = "/usr/sbin/screencapture -x -t png \"\(savePath)\""
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            let stderr = Pipe()
            process.standardError = stderr

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "ERROR: Could not run screencapture: \(error.localizedDescription)"
            }

            let exitCode = process.terminationStatus

            if exitCode != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                return """
                ERROR: screencapture failed (exit code \(exitCode)).
                Make sure Screen Recording is enabled in System Settings → Privacy & Security → Screen Recording.
                Details: \(errMsg)
                """
            }

            // Verify the file was created
            guard FileManager.default.fileExists(atPath: savePath) else {
                return """
                ERROR: Screenshot was not saved. This usually means Screen Recording permission was denied.
                Enable it in System Settings → Privacy & Security → Screen Recording → Apex Agent.
                """
            }

            // Get file info
            let attrs = try? FileManager.default.attributesOfItem(atPath: savePath)
            let fileSize = (attrs?[.size] as? Int64 ?? 0) / 1024

            // Get image dimensions
            var dimensions = ""
            if let nsImage = NSImage(contentsOfFile: savePath) {
                let w = Int(nsImage.size.width)
                let h = Int(nsImage.size.height)
                dimensions = "\nDimensions: \(w) × \(h) px"
            }

            return """
            ✅ Screenshot saved: \(savePath)
            File size: \(fileSize) KB\(dimensions)
            """
        }
    }

    @MainActor
    private func getFrontmostWindowID() -> UInt32? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let targetPID = frontmostApp.processIdentifier

        let options = CGWindowListOption.optionOnScreenOnly
        guard let windowListInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return nil
        }

        // The array is sorted from front to back by macOS window server.
        // So the first window belonging to targetPID with layer 0 is the frontmost window.
        for info in windowListInfo {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int,
                  pid == targetPID else {
                continue
            }

            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0 else {
                continue
            }

            if let windowID = info[kCGWindowNumber as String] as? UInt32 {
                return windowID
            }
        }

        return nil
    }
}
