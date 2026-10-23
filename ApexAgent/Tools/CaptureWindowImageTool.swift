import Foundation
import FoundationModels
import CoreGraphics
import AppKit

struct CaptureWindowImageTool: Tool {
    let orchestrator: OrchestratorProvider
    
    let name = "capture_window_image"
    let description = "Captures an application window frame by name or window ID without bringing the application frontmost or stealing display focus."
    
    @Generable struct Arguments: Decodable {
        let appName: String?
        let windowID: Int?
    }
    
    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await Task { @MainActor in
            let displayManager = VirtualDisplayManager.shared
            
            var targetWindowID: CGWindowID?
            
            if let wID = arguments.windowID {
                targetWindowID = CGWindowID(wID)
            } else if let appName = arguments.appName, !appName.isEmpty {
                let windows = displayManager.findWindows(forAppName: appName)
                targetWindowID = windows.first?.id
            }
            
            guard let windowID = targetWindowID else {
                return "ERROR: No matching window found."
            }
            
            guard let pngData = try? await displayManager.captureWindowPNGData(windowID: windowID) else {
                return "ERROR: Failed to capture window image for windowID \(windowID)."
            }
            
            let base64 = pngData.base64EncodedString()
            return "SUCCESS: Captured window image (size: \(pngData.count) bytes). Base64 preview prefix: \(base64.prefix(100))..."
        }.value
        }
    }
}
