import Foundation
import Testing
import CoreGraphics
@testable import ApexAgentCore

@Suite("Batch 77 — Virtual Display & Screen Streamer FPS & Memory Gate Tests")
struct ScreenStreamerResilienceAuditorTests {

    @Test("Standard 1024x768 stream configuration passes audit with 100% score")
    func standard1024x768StreamPasses() {
        let report = ScreenStreamerResilienceAuditor.auditStreamConfig(
            width: 1024,
            height: 768,
            targetFPS: 1.0,
            queueDepth: 3
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.metrics.frameSizeBytes == 1024 * 768 * 4)
        #expect(report.metrics.isWithinBudget)
        #expect(report.violations.isEmpty)
    }

    @Test("Excessive resolution or FPS triggers audit violations")
    func excessiveResolutionAndFPSTriggerViolations() {
        // Exceeds 3840x2160 and exceeds 60 FPS
        let report = ScreenStreamerResilienceAuditor.auditStreamConfig(
            width: 5120,
            height: 2880,
            targetFPS: 120.0,
            queueDepth: 10
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "RESOLUTION_EXCEEDS_CEILING" })
        #expect(report.violations.contains { $0.code == "FPS_EXCEEDS_LIMIT" })
        #expect(report.violations.contains { $0.code == "QUEUE_DEPTH_EXCESSIVE" })
        #expect(report.violations.contains { $0.code == "MEMORY_FOOTPRINT_EXCEEDED" })
    }

    @Test("Throughput metrics calculate accurate memory and bandwidth")
    func evaluateThroughputCalculatesAccurately() {
        // 1920x1080 at 30 FPS: 1920*1080*4 = 8,294,400 bytes per frame (~7.91 MB)
        // At 30 FPS, throughput is ~237.3 MB/s
        let metrics = ScreenStreamerResilienceAuditor.evaluateThroughput(
            width: 1920,
            height: 1080,
            fps: 30.0,
            queueDepth: 3
        )

        #expect(metrics.frameSizeBytes == 8_294_400)
        #expect(metrics.throughputMBPerSec > 230.0 && metrics.throughputMBPerSec < 240.0)
        #expect(metrics.totalQueueMemoryMB > 23.0 && metrics.totalQueueMemoryMB < 25.0)
        #expect(metrics.isWithinBudget)
    }

    @Test("Valid display contexts with primary display pass audit")
    func validDisplayContextsPass() {
        let mainDisplay = VirtualDisplayManager.DisplayContext(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            isMain: true,
            scaleFactor: 2.0
        )
        let secondaryDisplay = VirtualDisplayManager.DisplayContext(
            id: 2,
            bounds: CGRect(x: 2560, y: 0, width: 1920, height: 1080),
            isMain: false,
            scaleFactor: 1.0
        )

        let report = ScreenStreamerResilienceAuditor.auditDisplayContexts(displays: [mainDisplay, secondaryDisplay])
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.mainDisplayFound)
        #expect(report.totalDisplaysCount == 2)
        #expect(report.violations.isEmpty)
    }

    @Test("Missing primary display or invalid scale factor triggers violations")
    func missingMainDisplayOrBadScaleFactorFails() {
        let badDisplay = VirtualDisplayManager.DisplayContext(
            id: 1,
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            isMain: false,
            scaleFactor: 0.5 // Invalid scale factor
        )

        let report = ScreenStreamerResilienceAuditor.auditDisplayContexts(displays: [badDisplay])
        #expect(!report.passed)
        #expect(!report.mainDisplayFound)
        #expect(report.violations.contains { $0.code == "MISSING_MAIN_DISPLAY" })
        #expect(report.violations.contains { $0.code == "UNSUPPORTED_SCALE_FACTOR" })
    }
}
