import Testing
import Foundation
import CoreGraphics
@testable import ApexAgentCore

@Suite("Batch 66 — Accessibility Omni-Targeter & Screen Perception Coordinate Validator Tests")
struct ScreenPerceptionContractAuditorTests {

    private let standardDisplay = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test("Valid UI elements pass audit with score 100.0")
    func validElementsPass() {
        let elements = [
            TargetUIElementSpec(
                identifier: "btn-run",
                role: "AXButton",
                label: "Run Workflow",
                bounds: NormalizedScreenRect(x: 0.1, y: 0.2, width: 0.15, height: 0.05),
                isActionable: true
            ),
            TargetUIElementSpec(
                identifier: "tf-search",
                role: "AXTextField",
                label: "Search Input",
                bounds: NormalizedScreenRect(x: 0.3, y: 0.1, width: 0.4, height: 0.04),
                isActionable: true
            )
        ]

        let report = ScreenPerceptionContractAuditor.audit(elements: elements, displayBounds: standardDisplay)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.evaluatedElementsCount == 2)
        #expect(report.violations.isEmpty)
    }

    @Test("Coordinate conversion toDisplayPoints and fromDisplayPoints round-trips")
    func coordinateConversionRoundTrips() {
        let initial = NormalizedScreenRect(x: 0.25, y: 0.5, width: 0.1, height: 0.2)
        let pts = initial.toDisplayPoints(displayBounds: standardDisplay)

        #expect(pts.origin.x == 480.0)
        #expect(pts.origin.y == 540.0)
        #expect(pts.width == 192.0)
        #expect(pts.height == 216.0)

        let roundTrip = NormalizedScreenRect.fromDisplayPoints(rect: pts, displayBounds: standardDisplay)
        #expect(abs(roundTrip.x - initial.x) < 1e-5)
        #expect(abs(roundTrip.y - initial.y) < 1e-5)
        #expect(abs(roundTrip.width - initial.width) < 1e-5)
        #expect(abs(roundTrip.height - initial.height) < 1e-5)
    }

    @Test("Negative or non-positive coordinates trigger critical violation")
    func negativeCoordinatesTriggerCritical() {
        let bad = [
            TargetUIElementSpec(
                identifier: "bad-elem",
                role: "AXButton",
                label: "Broken Button",
                bounds: NormalizedScreenRect(x: -0.1, y: 0.0, width: 0.2, height: 0.1)
            )
        ]

        let report = ScreenPerceptionContractAuditor.audit(elements: bad, displayBounds: standardDisplay)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "COORD-002" && $0.severity == .critical })
    }

    @Test("Bounds extending outside viewport trigger high violation")
    func outOfBoundsCoordinatesTriggerHighViolation() {
        let overflow = [
            TargetUIElementSpec(
                identifier: "overflow-elem",
                role: "AXButton",
                label: "Offscreen Button",
                bounds: NormalizedScreenRect(x: 0.9, y: 0.8, width: 0.25, height: 0.1) // 0.9 + 0.25 = 1.15 > 1.0
            )
        ]

        let report = ScreenPerceptionContractAuditor.audit(elements: overflow, displayBounds: standardDisplay)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "COORD-003" && $0.severity == .high })
    }

    @Test("Actionable elements smaller than HIG minimum trigger medium violation")
    func tinyActionableElementsTriggerViolation() {
        let tiny = [
            TargetUIElementSpec(
                identifier: "tiny-dot",
                role: "AXButton",
                label: "Tiny Target",
                bounds: NormalizedScreenRect(x: 0.5, y: 0.5, width: 0.001, height: 0.001), // 1.9x1.0 pt < 8 pt
                isActionable: true
            )
        ]

        let report = ScreenPerceptionContractAuditor.audit(elements: tiny, displayBounds: standardDisplay)
        #expect(report.passed) // passes since medium violation score 90 >= 80
        #expect(report.violations.contains { $0.ruleId == "COORD-004" && $0.severity == .medium })
    }

    @Test("Perceptual buffer difference ratio detects identical and divergent frames")
    func differenceRatioCalculation() {
        let buf1: [UInt8] = [10, 20, 30, 40]
        let buf2: [UInt8] = [10, 20, 30, 40]
        let buf3: [UInt8] = [200, 200, 200, 200]

        #expect(ScreenPerceptionContractAuditor.computeDifferenceRatio(bufferA: buf1, bufferB: buf2) == 0.0)
        #expect(ScreenPerceptionContractAuditor.computeDifferenceRatio(bufferA: buf1, bufferB: buf3) == 1.0)
    }

    @Test("Report serializes to valid JSON")
    func reportSerializesToJSON() {
        let report = ScreenPerceptionContractAuditor.audit(elements: [])
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
    }
}
