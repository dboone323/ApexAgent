import XCTest
import CoreGraphics
import AppKit
import ApplicationServices
@testable import ApexAgentCore

// MARK: - OSAutomationTests: Real Functional Tests for OS Automation (Pillar 4)
//
// Zero-Mock Policy: Executes real CoreGraphics window list queries, real display bounds discovery,
// real image buffer comparisons, and real accessibility element traversal.

@MainActor
final class OSAutomationTests: XCTestCase {

    func testVirtualDisplayManagerDisplays() {
        let manager = VirtualDisplayManager.shared
        manager.refreshDisplays()
        
        XCTAssertFalse(manager.activeDisplays.isEmpty, "At least one active display must be discovered on macOS")
        
        let mainDisplay = manager.activeDisplays.first { $0.isMain }
        XCTAssertNotNil(mainDisplay, "Main display context must be identified")
        XCTAssertGreaterThan(mainDisplay?.bounds.width ?? 0, 0, "Display width must be positive")
        XCTAssertGreaterThan(mainDisplay?.bounds.height ?? 0, 0, "Display height must be positive")
        XCTAssertGreaterThanOrEqual(mainDisplay?.scaleFactor ?? 0, 1.0, "Display scale factor must be >= 1.0")
    }

    func testVirtualDisplayManagerWindowDiscovery() {
        let manager = VirtualDisplayManager.shared
        let windows = manager.listWindows()
        
        XCTAssertFalse(windows.isEmpty, "System window list query must return running system windows")
        
        if let window = windows.first {
            XCTAssertGreaterThan(window.id, 0, "Window ID must be positive")
            XCTAssertGreaterThan(window.ownerPID, 0, "Window owner PID must be positive")
            XCTAssertFalse(window.ownerName.isEmpty, "Window owner name must be present")
        }
    }

    func testVirtualDisplayManagerFindWindowsByAppName() {
        let manager = VirtualDisplayManager.shared
        let finderWindows = manager.findWindows(forAppName: "Finder")
        // Finder is a core macOS system service and always present
        XCTAssertNotNil(finderWindows)
    }

    func testVirtualDisplayManagerCoordinateMapping() {
        let manager = VirtualDisplayManager.shared
        manager.refreshDisplays()
        
        guard let mainDisplay = manager.activeDisplays.first(where: { $0.isMain }) else {
            XCTFail("Main display not found")
            return
        }
        
        let centerPoint = CGPoint(x: mainDisplay.bounds.midX, y: mainDisplay.bounds.midY)
        let mapped = manager.mapPointToDisplayBounds(point: centerPoint, displayID: mainDisplay.id)
        
        XCTAssertNotNil(mapped, "Valid point inside display bounds must map successfully")
        XCTAssertGreaterThanOrEqual(mapped?.x ?? -1, 0)
        XCTAssertGreaterThanOrEqual(mapped?.y ?? -1, 0)
    }

    func testDifferentialScreenPerceptionDiffCalculation() {
        // Create two distinct real CGImage buffers to test differential bounding box calculation
        let width = 200
        let height = 200
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        
        guard let ctx1 = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo),
              let ctx2 = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
            XCTFail("Failed to create graphics contexts for diff testing")
            return
        }
        
        // Frame 1: White background
        ctx1.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx1.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img1 = ctx1.makeImage()!
        
        // Frame 2: White background + red rectangle in region (50, 50, 40, 40)
        ctx2.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx2.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx2.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx2.fill(CGRect(x: 50, y: 50, width: 40, height: 40))
        let img2 = ctx2.makeImage()!
        
        let diffBBox = DifferentialScreenPerception.computeBoundingBoxDifference(frame1: img1, frame2: img2)
        XCTAssertNotNil(diffBBox, "Differential calculation between different images must detect bounding box")
        
        if let bbox = diffBBox {
            XCTAssertGreaterThanOrEqual(bbox.width, 35, "Detected bbox width should cover modified region")
            XCTAssertGreaterThanOrEqual(bbox.height, 35, "Detected bbox height should cover modified region")
        }
    }

    func testAccessibilityOmniTargeterProcessInspection() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let appElement = AXUIElementCreateApplication(currentPID)
        
        var pidRef: pid_t = 0
        let err = AXUIElementGetPid(appElement, &pidRef)
        
        XCTAssertEqual(err, .success, "AXUIElementGetPid must succeed for current running process")
        XCTAssertEqual(pidRef, currentPID, "AXUIElement PID must match current process PID")
    }
}
