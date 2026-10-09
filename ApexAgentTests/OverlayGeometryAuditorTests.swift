import Foundation
import CoreGraphics
import Testing
@testable import ApexAgentCore

@Suite("Batch 86 — Ghost Cursor & Screen Highlight Overlay Coordinate Clamp Gate Tests")
struct OverlayGeometryAuditorTests {

    let screen1080p = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("Point origin conversion between top-left and bottom-left is reciprocal")
    func pointOriginConversionReciprocal() {
        let initialPoint = CGPoint(x: 350, y: 150)
        let converted = OverlayGeometryAuditor.convertPointOrigin(
            initialPoint,
            screenHeight: 1080,
            from: .topLeft,
            to: .bottomLeft
        )

        #expect(converted.x == 350.0)
        #expect(converted.y == 930.0)

        let roundTrip = OverlayGeometryAuditor.convertPointOrigin(
            converted,
            screenHeight: 1080,
            from: .bottomLeft,
            to: .topLeft
        )

        #expect(roundTrip == initialPoint)
    }

    @Test("Rect origin conversion between top-left and bottom-left preserves rect shape and is reciprocal")
    func rectOriginConversionReciprocal() {
        let initialRect = CGRect(x: 200, y: 100, width: 400, height: 300)
        let converted = OverlayGeometryAuditor.convertRectOrigin(
            initialRect,
            screenHeight: 1080,
            from: .topLeft,
            to: .bottomLeft
        )

        // new_y = 1080 - 100 - 300 = 680
        #expect(converted.origin.x == 200)
        #expect(converted.origin.y == 680)
        #expect(converted.width == 400)
        #expect(converted.height == 300)

        let roundTrip = OverlayGeometryAuditor.convertRectOrigin(
            converted,
            screenHeight: 1080,
            from: .bottomLeft,
            to: .topLeft
        )

        #expect(roundTrip == initialRect)
    }

    @Test("Point clamping restricts cursor coordinates to valid screen boundaries")
    func pointClampingWithinScreen() {
        // Within bounds
        let pInside = CGPoint(x: 500, y: 500)
        let (clampedInside, wasClampedInside) = OverlayGeometryAuditor.clampPoint(pInside, to: screen1080p)
        #expect(clampedInside == pInside)
        #expect(!wasClampedInside)

        // Offscreen negative
        let pNeg = CGPoint(x: -120, y: -40)
        let (clampedNeg, wasClampedNeg) = OverlayGeometryAuditor.clampPoint(pNeg, to: screen1080p)
        #expect(clampedNeg == CGPoint(x: 0, y: 0))
        #expect(wasClampedNeg)

        // Offscreen overshoot
        let pOver = CGPoint(x: 2500, y: 1200)
        let (clampedOver, wasClampedOver) = OverlayGeometryAuditor.clampPoint(pOver, to: screen1080p)
        #expect(clampedOver == CGPoint(x: 1920, y: 1080))
        #expect(wasClampedOver)
    }

    @Test("Rect clamping clips overflowing rects to visible screen frame")
    func rectClampingClipsToFrame() {
        let overflowRect = CGRect(x: 1800, y: 1000, width: 300, height: 200)
        let result = OverlayGeometryAuditor.clampRect(overflowRect, to: screen1080p)

        #expect(result.wasClamped)
        #expect(result.clamped.maxX <= screen1080p.maxX)
        #expect(result.clamped.maxY <= screen1080p.maxY)
        #expect(result.clamped.width == 120) // 1920 - 1800
        #expect(result.clamped.height == 80) // 1080 - 1000
    }

    @Test("Valid highlight rects pass audit with 100% score")
    func validHighlightRectsPass() {
        let rects = [
            CGRect(x: 50, y: 50, width: 200, height: 100),
            CGRect(x: 300, y: 400, width: 500, height: 250)
        ]

        let report = OverlayGeometryAuditor.auditHighlightRects(rects: rects, screenBounds: screen1080p)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.totalRectsCount == 2)
        #expect(report.violations.isEmpty)
    }

    @Test("Offscreen, invalid, and overflowing rects produce appropriate violations")
    func invalidHighlightRectsProduceViolations() {
        let rects = [
            CGRect(x: 3000, y: 3000, width: 200, height: 200), // Entirely offscreen
            CGRect(x: 100, y: 100, width: -50, height: 100),   // Negative width
            CGRect(x: 1850, y: 100, width: 200, height: 100)   // Partially offscreen
        ]

        let report = OverlayGeometryAuditor.auditHighlightRects(rects: rects, screenBounds: screen1080p)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "ENTIRELY_OFFSCREEN" })
        #expect(report.violations.contains { $0.code == "NON_POSITIVE_DIMENSIONS" })
        #expect(report.violations.contains { $0.code == "PARTIALLY_OFFSCREEN" })
    }

    @Test("Empty rects list produces fatal violation")
    func emptyRectsListFails() {
        let report = OverlayGeometryAuditor.auditHighlightRects(rects: [], screenBounds: screen1080p)

        #expect(!report.passed)
        #expect(report.score == 0.0)
        #expect(report.violations.contains { $0.code == "EMPTY_OVERLAY_RECTS" })
    }
}
