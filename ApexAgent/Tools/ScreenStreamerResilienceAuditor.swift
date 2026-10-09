import Foundation
import CoreGraphics

// MARK: - Screen Streamer & Virtual Display Resilience Gate (Batch 77)

/// Configuration policy for screen streamer memory and performance constraints.
public struct ScreenStreamerPolicy: Sendable, Codable, Equatable {
    public var maxWidth: Int
    public var maxHeight: Int
    public var minWidth: Int
    public var minHeight: Int
    public var maxFPS: Double
    public var maxQueueDepth: Int
    public var maxMemoryFootprintMB: Double

    public init(
        maxWidth: Int = 3840,
        maxHeight: Int = 2160,
        minWidth: Int = 320,
        minHeight: Int = 240,
        maxFPS: Double = 60.0,
        maxQueueDepth: Int = 5,
        maxMemoryFootprintMB: Double = 150.0
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxFPS = maxFPS
        self.maxQueueDepth = maxQueueDepth
        self.maxMemoryFootprintMB = maxMemoryFootprintMB
    }
}

/// Calculated metrics for a streaming configuration.
public struct StreamThroughputMetrics: Sendable, Codable, Equatable {
    public let frameSizeBytes: Int
    public let throughputMBPerSec: Double
    public let totalQueueMemoryMB: Double
    public let isWithinBudget: Bool
}

/// Violation detected during screen streaming configuration audit.
public struct StreamAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by auditing a screen capture stream configuration.
public struct StreamConfigAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let metrics: StreamThroughputMetrics
    public let violations: [StreamAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        metrics: StreamThroughputMetrics,
        violations: [StreamAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.metrics = metrics
        self.violations = violations
    }
}

/// Report produced by auditing display contexts.
public struct DisplayContextAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalDisplaysCount: Int
    public let mainDisplayFound: Bool
    public let violations: [StreamAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        totalDisplaysCount: Int,
        mainDisplayFound: Bool,
        violations: [StreamAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalDisplaysCount = totalDisplaysCount
        self.mainDisplayFound = mainDisplayFound
        self.violations = violations
    }
}

/// Resilience auditor for ScreenCaptureKit configurations and virtual displays.
public enum ScreenStreamerResilienceAuditor {

    // MARK: - Throughput Calculation

    /// Computes memory footprint per frame (assuming 32-bit BGRA: 4 bytes/pixel), bandwidth, and queue memory.
    public static func evaluateThroughput(
        width: Int,
        height: Int,
        fps: Double,
        queueDepth: Int = 3,
        policy: ScreenStreamerPolicy = ScreenStreamerPolicy()
    ) -> StreamThroughputMetrics {
        let frameSize = width * height * 4
        let throughputBytes = Double(frameSize) * fps
        let throughputMB = throughputBytes / (1024.0 * 1024.0)
        let queueMemoryMB = Double(frameSize * queueDepth) / (1024.0 * 1024.0)
        let withinBudget = queueMemoryMB <= policy.maxMemoryFootprintMB

        return StreamThroughputMetrics(
            frameSizeBytes: frameSize,
            throughputMBPerSec: throughputMB,
            totalQueueMemoryMB: queueMemoryMB,
            isWithinBudget: withinBudget
        )
    }

    // MARK: - Stream Config Audit

    /// Audits a ScreenCaptureKit stream configuration for resolution ceilings, FPS limits, queue depth, and memory budgets.
    public static func auditStreamConfig(
        width: Int,
        height: Int,
        targetFPS: Double,
        queueDepth: Int,
        policy: ScreenStreamerPolicy = ScreenStreamerPolicy()
    ) -> StreamConfigAuditReport {
        var violations: [StreamAuditViolation] = []

        // 1. Resolution checks
        if width > policy.maxWidth || height > policy.maxHeight {
            violations.append(StreamAuditViolation(
                code: "RESOLUTION_EXCEEDS_CEILING",
                message: "Resolution \(width)x\(height) exceeds policy maximum of \(policy.maxWidth)x\(policy.maxHeight)."
            ))
        }
        if width < policy.minWidth || height < policy.minHeight {
            violations.append(StreamAuditViolation(
                code: "RESOLUTION_BELOW_FLOOR",
                message: "Resolution \(width)x\(height) is below minimum of \(policy.minWidth)x\(policy.minHeight)."
            ))
        }

        // 2. FPS checks
        if targetFPS > policy.maxFPS {
            violations.append(StreamAuditViolation(
                code: "FPS_EXCEEDS_LIMIT",
                message: "Target FPS \(targetFPS) exceeds policy maximum of \(policy.maxFPS) FPS."
            ))
        }
        if targetFPS <= 0 {
            violations.append(StreamAuditViolation(
                code: "INVALID_FPS",
                message: "Target FPS must be strictly positive."
            ))
        }

        // 3. Queue depth check
        if queueDepth > policy.maxQueueDepth {
            violations.append(StreamAuditViolation(
                code: "QUEUE_DEPTH_EXCESSIVE",
                message: "Queue depth \(queueDepth) exceeds maximum allowable buffer queue of \(policy.maxQueueDepth)."
            ))
        }
        if queueDepth < 1 {
            violations.append(StreamAuditViolation(
                code: "QUEUE_DEPTH_INVALID",
                message: "Queue depth must be at least 1."
            ))
        }

        let metrics = evaluateThroughput(width: width, height: height, fps: targetFPS, queueDepth: queueDepth, policy: policy)
        if !metrics.isWithinBudget {
            violations.append(StreamAuditViolation(
                code: "MEMORY_FOOTPRINT_EXCEEDED",
                message: "Queue buffer memory \(String(format: "%.1f", metrics.totalQueueMemoryMB)) MB exceeds maximum ceiling of \(policy.maxMemoryFootprintMB) MB."
            ))
        }

        let passed = violations.isEmpty
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 25.0)

        return StreamConfigAuditReport(
            passed: passed,
            score: score,
            metrics: metrics,
            violations: violations
        )
    }

    // MARK: - Display Context Audit

    /// Audits active display contexts for scale factors, valid bounds, and primary display presence.
    public static func auditDisplayContexts(
        displays: [VirtualDisplayManager.DisplayContext]
    ) -> DisplayContextAuditReport {
        var violations: [StreamAuditViolation] = []

        guard !displays.isEmpty else {
            violations.append(StreamAuditViolation(code: "NO_DISPLAYS_DETECTED", message: "Zero active displays were discovered."))
            return DisplayContextAuditReport(
                passed: false,
                score: 0.0,
                totalDisplaysCount: 0,
                mainDisplayFound: false,
                violations: violations
            )
        }

        let mainCount = displays.filter(\.isMain).count
        if mainCount == 0 {
            violations.append(StreamAuditViolation(code: "MISSING_MAIN_DISPLAY", message: "No display marked as primary/main."))
        } else if mainCount > 1 {
            violations.append(StreamAuditViolation(code: "MULTIPLE_MAIN_DISPLAYS", message: "Multiple displays marked as primary/main.", isFatal: false))
        }

        for (idx, display) in displays.enumerated() {
            if display.scaleFactor < 1.0 || display.scaleFactor > 3.0 {
                violations.append(StreamAuditViolation(
                    code: "UNSUPPORTED_SCALE_FACTOR",
                    message: "Display \(idx) has abnormal scale factor: \(display.scaleFactor)."
                ))
            }
            if display.bounds.width <= 0 || display.bounds.height <= 0 {
                violations.append(StreamAuditViolation(
                    code: "INVALID_DISPLAY_BOUNDS",
                    message: "Display \(idx) has non-positive dimensions: \(display.bounds.width)x\(display.bounds.height)."
                ))
            }
        }

        let passed = violations.filter(\.isFatal).isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 80.0) : max(0.0, 100.0 - Double(violations.count) * 30.0)

        return DisplayContextAuditReport(
            passed: passed,
            score: score,
            totalDisplaysCount: displays.count,
            mainDisplayFound: mainCount == 1,
            violations: violations
        )
    }
}
