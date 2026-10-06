import Foundation
import CoreGraphics
import AppKit
import Observation
import ScreenCaptureKit

// MARK: - VirtualDisplayManager
//
// Manages display contexts and off-screen window image capture for background bot automation.
// Allows ApexAgent to inspect, target, and capture application window buffers without
// requiring the target application to steal user focus or hijack the primary display.

@Observable
@MainActor
public final class VirtualDisplayManager {
    public static let shared = VirtualDisplayManager()
    
    // MARK: - Types
    
    public struct WindowInfo: Identifiable, Sendable {
        public let id: CGWindowID
        public let ownerPID: pid_t
        public let ownerName: String
        public let windowTitle: String
        public let bounds: CGRect
        public let isOnScreen: Bool
        
        public init(id: CGWindowID, ownerPID: pid_t, ownerName: String, windowTitle: String, bounds: CGRect, isOnScreen: Bool) {
            self.id = id
            self.ownerPID = ownerPID
            self.ownerName = ownerName
            self.windowTitle = windowTitle
            self.bounds = bounds
            self.isOnScreen = isOnScreen
        }
    }
    
    public struct DisplayContext: Identifiable, Sendable {
        public let id: CGDirectDisplayID
        public let bounds: CGRect
        public let isMain: Bool
        public let scaleFactor: CGFloat
        
        public init(id: CGDirectDisplayID, bounds: CGRect, isMain: Bool, scaleFactor: CGFloat) {
            self.id = id
            self.bounds = bounds
            self.isMain = isMain
            self.scaleFactor = scaleFactor
        }
    }
    
    // MARK: - Properties
    
    public private(set) var activeDisplays: [DisplayContext] = []
    public private(set) var capturedWindows: [WindowInfo] = []
    
    public init() {
        refreshDisplays()
    }
    
    // MARK: - Display Management
    
    public func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        
        let mainID = CGMainDisplayID()
        
        self.activeDisplays = displays.map { dID in
            let bounds = CGDisplayBounds(dID)
            let isMain = (dID == mainID)
            let matchingScreen = NSScreen.screens.first { screen in
                let sNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
                return sNumber == dID
            }
            let scaleFactor = matchingScreen?.backingScaleFactor ?? 1.0
            return DisplayContext(id: dID, bounds: bounds, isMain: isMain, scaleFactor: scaleFactor)
        }
    }
    
    // MARK: - Window Discovery
    
    public func listWindows(onScreenOnly: Bool = false) -> [WindowInfo] {
        let options: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        
        var results: [WindowInfo] = []
        
        for dict in infoList {
            guard let windowID = dict[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = dict[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            
            let ownerName = dict[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let windowTitle = dict[kCGWindowName as String] as? String ?? ""
            let isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
            
            var bounds = CGRect.zero
            if let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
               let x = boundsDict["X"], let y = boundsDict["Y"],
               let w = boundsDict["Width"], let h = boundsDict["Height"] {
                bounds = CGRect(x: x, y: y, width: w, height: h)
            }
            
            let info = WindowInfo(
                id: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowTitle: windowTitle,
                bounds: bounds,
                isOnScreen: isOnScreen
            )
            results.append(info)
        }
        
        self.capturedWindows = results
        return results
    }
    
    public func findWindows(forAppName appName: String) -> [WindowInfo] {
        return listWindows().filter {
            $0.ownerName.localizedCaseInsensitiveContains(appName)
        }
    }
    
    public func findWindows(forPID pid: pid_t) -> [WindowInfo] {
        return listWindows().filter { $0.ownerPID == pid }
    }
    
    // MARK: - Off-Screen Window Capture
    
    public func captureWindow(windowID: CGWindowID) async throws -> CGImage? {
        guard #available(macOS 14.0, *) else { return nil }
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
            return nil
        }
        
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(window.frame.width))
        config.height = max(1, Int(window.frame.height))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
    
    public func captureWindowPNGData(windowID: CGWindowID) async throws -> Data? {
        guard let cgImage = try await captureWindow(windowID: windowID) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .png, properties: [:])
    }
    
    // MARK: - Coordinate Mapping
    
    public func mapPointToDisplayBounds(point: CGPoint, displayID: CGDirectDisplayID) -> CGPoint? {
        guard let display = activeDisplays.first(where: { $0.id == displayID }) else { return nil }
        let bounds = display.bounds
        guard bounds.contains(point) else { return nil }
        return CGPoint(x: point.x - bounds.origin.x, y: point.y - bounds.origin.y)
    }

    // MARK: - Markdown Telemetry

    public func formatDisplayStatusMarkdown() -> String {
        guard !activeDisplays.isEmpty else {
            return "No active display devices detected."
        }

        var md = "### 🖥️ Virtual Display & Off-Screen Window Subsystem (\(activeDisplays.count) displays)\n\n"
        md += "| Display ID | Primary | Resolution (Bounds) | Backing Scale |\n"
        md += "|---|---|---|---|\n"

        for d in activeDisplays {
            let primaryStr = d.isMain ? "⭐ Yes" : "No"
            let resStr = "\(Int(d.bounds.width))x\(Int(d.bounds.height))"
            let scaleStr = String(format: "%.1fx", d.scaleFactor)
            md += "| `\(d.id)` | \(primaryStr) | `\(resStr)` | `\(scaleStr)` |\n"
        }
        return md
    }

}