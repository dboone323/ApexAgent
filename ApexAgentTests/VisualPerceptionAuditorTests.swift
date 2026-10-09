import Foundation
import CoreGraphics
import Testing
@testable import ApexAgentCore

@Suite("Batch 92 — Differential Screen Perception Thresholds & Visual Change Gate Tests")
struct VisualPerceptionAuditorTests {

    @Test("Identical pixel buffers produce zero change and no dirty bounding box")
    func identicalBuffersProduceZeroChange() {
        let size = 100 * 100
        let frameA = [UInt8](repeating: 128, count: size)
        let frameB = [UInt8](repeating: 128, count: size)

        let report = VisualPerceptionAuditor.evaluatePixelDifference(
            bufferA: frameA,
            bufferB: frameB,
            width: 100,
            height: 100
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(!report.evaluation.isSignificantChange)
        #expect(report.evaluation.changedPixelPercentage == 0.0)
        #expect(report.evaluation.hammingDistance == 0)
        #expect(report.evaluation.dirtyBoundingBoxes.isEmpty)
        #expect(report.violations.isEmpty)
    }

    @Test("Substantial screen change produces significant change flag and bounding box")
    func substantialChangeDetected() {
        let width = 100
        let height = 100
        var frameA = [UInt8](repeating: 50, count: width * height)
        var frameB = frameA

        // Paint a 30x30 bright region (900 pixels = 9% of screen) at (20, 20)
        for y in 20..<50 {
            for x in 20..<50 {
                frameB[y * width + x] = 240
            }
        }

        let report = VisualPerceptionAuditor.evaluatePixelDifference(
            bufferA: frameA,
            bufferB: frameB,
            width: width,
            height: height
        )

        #expect(report.passed)
        #expect(report.evaluation.isSignificantChange)
        #expect(report.evaluation.changedPixelPercentage >= 8.9)
        #expect(!report.evaluation.dirtyBoundingBoxes.isEmpty)

        // Verify bounding box coordinates cover the painted region
        if let box = report.evaluation.dirtyBoundingBoxes.first {
            #expect(box.origin.x <= 20)
            #expect(box.origin.y <= 20)
            #expect(box.maxX >= 49)
            #expect(box.maxY >= 49)
        }
    }

    @Test("Minor noise below 0.5% threshold is filtered as not significant")
    func minorNoiseFiltered() {
        let width = 100
        let height = 100
        var frameA = [UInt8](repeating: 100, count: width * height)
        var frameB = frameA

        // Modify only 2 pixels (0.02% of screen)
        frameB[0] = 200
        frameB[1] = 200

        let report = VisualPerceptionAuditor.evaluatePixelDifference(
            bufferA: frameA,
            bufferB: frameB,
            width: width,
            height: height
        )

        #expect(report.passed)
        #expect(!report.evaluation.isSignificantChange)
        #expect(report.evaluation.changedPixelPercentage < 0.5)
    }

    @Test("Hamming distance computation calculates bit differences accurately")
    func hammingDistanceAccurate() {
        let h1: UInt64 = 0b1111_0000
        let h2: UInt64 = 0b0000_1111
        #expect(VisualPerceptionAuditor.computeHammingDistance(h1, h2) == 8)

        let hSame: UInt64 = 0xDEADBEEF_CAFEF00D
        #expect(VisualPerceptionAuditor.computeHammingDistance(hSame, hSame) == 0)
    }

    @Test("Mismatched buffer sizes and non-positive dimensions fail with violations")
    func invalidInputsProduceViolations() {
        // Mismatched count
        let report1 = VisualPerceptionAuditor.evaluatePixelDifference(
            bufferA: [1, 2, 3],
            bufferB: [1, 2],
            width: 10,
            height: 10
        )
        #expect(!report1.passed)
        #expect(report1.violations.contains { $0.code == "BUFFER_SIZE_MISMATCH" })

        // Non-positive dimensions
        let report2 = VisualPerceptionAuditor.evaluatePixelDifference(
            bufferA: [],
            bufferB: [],
            width: 0,
            height: 10
        )
        #expect(!report2.passed)
        #expect(report2.violations.contains { $0.code == "INVALID_IMAGE_DIMENSIONS" })
    }
}
