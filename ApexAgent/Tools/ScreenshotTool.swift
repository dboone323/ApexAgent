import Foundation
import FoundationModels
import AppKit
import CoreGraphics
import ScreenCaptureKit

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

        @Guide(description: "If true, uses fast ScreenCaptureKit instead of fallback screencapture. Defaults to true.")
        var fast: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            // Probe the actual macOS TCC state instead of trusting a stored boolean
            // that defaults to false and is never set to true by the OS after a grant.
            // CGPreflightScreenCaptureAccess() is the same probe DiagnosticManager uses.
            guard CGPreflightScreenCaptureAccess() else {
                return "ERROR: Screen Recording is not permitted by macOS. Enable it in System Settings → Privacy & Security → Screen Recording, grant access to Apex Agent / Hermes, then retry."
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
            let fast = arguments.fast ?? true

            if fast, #available(macOS 14.0, *) {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    let filter: SCContentFilter
                    if windowOnly {
                        let targetWindowID = await MainActor.run { self.getFrontmostWindowID() }
                        if let wId = targetWindowID, let targetWindow = content.windows.first(where: { $0.windowID == wId }) {
                            filter = SCContentFilter(desktopIndependentWindow: targetWindow)
                        } else if let display = content.displays.first {
                            filter = SCContentFilter(display: display, excludingWindows: [])
                        } else {
                            throw NSError(domain: "ScreenshotTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
                        }
                    } else {
                        if let display = content.displays.first {
                            filter = SCContentFilter(display: display, excludingWindows: [])
                        } else {
                            throw NSError(domain: "ScreenshotTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
                        }
                    }
                    
                    let config = SCStreamConfiguration()
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    
                    let nsImage = NSImage(cgImage: cgImage, size: .zero)
                    guard let tiffData = nsImage.tiffRepresentation,
                          let bitmapImage = NSBitmapImageRep(data: tiffData),
                          let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "ScreenshotTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to convert image to PNG"])
                    }
                    
                    try pngData.write(to: URL(fileURLWithPath: savePath))
                    
                    let fileSize = pngData.count / 1024
                    let w = Int(nsImage.size.width)
                    let h = Int(nsImage.size.height)
                    let dimensions = "\nDimensions: \\(w) × \\(h) px"
                    
                    return """
                    ✅ Screenshot saved (fast mode): \\(savePath)
                    File size: \\(fileSize) KB\\(dimensions)
                    """
                } catch {
                    return "ERROR: ScreenCaptureKit capture failed: \\(error.localizedDescription)"
                }
            }

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
                command = "/usr/sbin/screencapture -x -t png -o -l \\(wId) \"\\(savePath)\""
            } else {
                command = "/usr/sbin/screencapture -x -t png \"\\(savePath)\""
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]

            let stderr = Pipe()
            process.standardError = stderr

            do {
                try process.run()
                let screenshotWatchdog = Task {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if process.isRunning { process.terminate() }
                }
                process.waitUntilExit()
                screenshotWatchdog.cancel()
            } catch {
                return "ERROR: Could not run screencapture: \\(error.localizedDescription)"
            }

            let exitCode = process.terminationStatus

            if exitCode != 0 {
                let errData = stderr.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
                return """
                ERROR: screencapture failed (exit code \\(exitCode)).
                Make sure Screen Recording is enabled in System Settings → Privacy & Security → Screen Recording.
                Details: \\(errMsg)
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
                dimensions = "\nDimensions: \\(w) × \\(h) px"
            }

            return """
            ✅ Screenshot saved: \\(savePath)
            File size: \\(fileSize) KB\\(dimensions)
            """
        }
    }

    public func captureToData() async throws -> Data {
        guard #available(macOS 14.0, *) else {
            throw NSError(domain: "ScreenshotTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "captureToData requires macOS 14.0+"])
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "ScreenshotTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let nsImage = NSImage(cgImage: cgImage, size: .zero)
        guard let tiffData = nsImage.tiffRepresentation,
              let bitmapImage = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScreenshotTool", code: -3, userInfo: [NSLocalizedDescriptionKey: "Image encoding failed"])
        }
        return pngData
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
