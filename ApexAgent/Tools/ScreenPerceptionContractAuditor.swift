import Foundation
import CoreGraphics

// MARK: - Accessibility Omni-Targeter & Screen Perception Coordinate Validator (Batch 66)

/// A rectangular region on screen defined by normalized coordinates [0.0 ... 1.0].
public struct NormalizedScreenRect: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Converts normalized bounds to absolute display points.
    public func toDisplayPoints(displayBounds: CGRect) -> CGRect {
        CGRect(
            x: displayBounds.origin.x + (x * displayBounds.width),
            y: displayBounds.origin.y + (y * displayBounds.height),
            width: width * displayBounds.width,
            height: height * displayBounds.height
        )
    }

    /// Converts absolute points to normalized bounds.
    public static func fromDisplayPoints(rect: CGRect, displayBounds: CGRect) -> NormalizedScreenRect {
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            return NormalizedScreenRect(x: 0, y: 0, width: 0, height: 0)
        }
        let normX = (rect.origin.x - displayBounds.origin.x) / displayBounds.width
        let normY = (rect.origin.y - displayBounds.origin.y) / displayBounds.height
        let normW = rect.width / displayBounds.width
        let normH = rect.height / displayBounds.height
        return NormalizedScreenRect(x: normX, y: normY, width: normW, height: normH)
    }
}

/// An interactive UI element discovered via Accessibility tree or computer vision.
public struct TargetUIElementSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(role):\(identifier):\(label)" }
    public let identifier: String
    public let role: String
    public let label: String
    public let bounds: NormalizedScreenRect
    public let isActionable: Bool

    public init(
        identifier: String,
        role: String,
        label: String,
        bounds: NormalizedScreenRect,
        isActionable: Bool = true
    ) {
        self.identifier = identifier
        self.role = role
        self.label = label
        self.bounds = bounds
        self.isActionable = isActionable
    }
}

/// Violation detected during screen coordinate or accessibility target validation.
public struct ScreenPerceptionViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(targetId):\(ruleId):\(message)" }
    public let targetId: String
    public let ruleId: String
    public let severity: ToolSandboxSeverity
    public let message: String
    public let remediation: String

    public init(
        targetId: String,
        ruleId: String,
        severity: ToolSandboxSeverity,
        message: String,
        remediation: String
    ) {
        self.targetId = targetId
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Aggregated report produced by `ScreenPerceptionContractAuditor`.
public struct ScreenPerceptionAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedElementsCount: Int
    public let violations: [ScreenPerceptionViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedElementsCount: Int,
        violations: [ScreenPerceptionViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedElementsCount = evaluatedElementsCount
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous auditor verifying screen perception coordinate normalization,
/// accessibility target click bounds sanity, and retina scaling integrity.
public enum ScreenPerceptionContractAuditor {

    public static let minimumClickTargetPointSize: Double = 8.0 // Apple HIG minimum tap/click area

    /// Audits a set of target UI elements across display spaces.
    public static func audit(
        elements: [TargetUIElementSpec],
        displayBounds: CGRect = CGRect(x: 0, y: 0, width: 1920, height: 1080),
        scaleFactor: Double = 2.0 // Retina 2x
    ) -> ScreenPerceptionAuditReport {
        guard !elements.isEmpty else {
            return ScreenPerceptionAuditReport(
                passed: true,
                score: 100.0,
                evaluatedElementsCount: 0,
                violations: [],
                recommendations: ["No UI elements evaluated."]
            )
        }

        var violations: [ScreenPerceptionViolation] = []

        for element in elements {
            let rect = element.bounds

            // Rule 1: Non-NaN and finite coordinates
            if rect.x.isNaN || rect.y.isNaN || rect.width.isNaN || rect.height.isNaN ||
               rect.x.isInfinite || rect.y.isInfinite || rect.width.isInfinite || rect.height.isInfinite {
                violations.append(
                    ScreenPerceptionViolation(
                        targetId: element.identifier,
                        ruleId: "COORD-001",
                        severity: .critical,
                        message: "Element '\(element.label)' contains NaN or infinite coordinates.",
                        remediation: "Ensure Vision / Accessibility bounding boxes are properly sanitized."
                    )
                )
                continue
            }

            // Rule 2: Normalized coordinate range [0.0 ... 1.0]
            if rect.x < 0.0 || rect.y < 0.0 || rect.width <= 0.0 || rect.height <= 0.0 {
                violations.append(
                    ScreenPerceptionViolation(
                        targetId: element.identifier,
                        ruleId: "COORD-002",
                        severity: .critical,
                        message: "Element '\(element.label)' has negative origins or non-positive dimensions (x: \(rect.x), y: \(rect.y), w: \(rect.width), h: \(rect.height)).",
                        remediation: "Clamp normalized coordinates within [0.0 ... 1.0]."
                    )
                )
            }

            // Rule 3: Coordinate bounds overflow (> 1.0)
            let right = rect.x + rect.width
            let bottom = rect.y + rect.height
            if right > 1.001 || bottom > 1.001 {
                violations.append(
                    ScreenPerceptionViolation(
                        targetId: element.identifier,
                        ruleId: "COORD-003",
                        severity: .high,
                        message: "Element '\(element.label)' extends outside display boundary (right: \(String(format: "%.3f", right)), bottom: \(String(format: "%.3f", bottom))).",
                        remediation: "Intersect element bounds with display viewport."
                    )
                )
            }

            // Rule 4: Actionable element click target size check
            if element.isActionable {
                let pts = rect.toDisplayPoints(displayBounds: displayBounds)
                if pts.width < minimumClickTargetPointSize || pts.height < minimumClickTargetPointSize {
                    violations.append(
                        ScreenPerceptionViolation(
                            targetId: element.identifier,
                            ruleId: "COORD-004",
                            severity: .medium,
                            message: "Actionable element '\(element.label)' has size (\(String(format: "%.1f", pts.width))x\(String(format: "%.1f", pts.height)) pt) smaller than minimum HIG click target of \(minimumClickTargetPointSize) pt.",
                            remediation: "Pad interactive target click zone to at least 8x8 points."
                        )
                    )
                }
            }
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Clamp element bounding boxes within display viewport and verify Vision coordinate conversion.")
        }

        return ScreenPerceptionAuditReport(
            passed: passed,
            score: score,
            evaluatedElementsCount: elements.count,
            violations: violations,
            recommendations: recs
        )
    }

    /// Computes perceptual hash difference between two grayscale or color image buffers.
    public static func computeDifferenceRatio(bufferA: [UInt8], bufferB: [UInt8]) -> Double {
        guard !bufferA.isEmpty, bufferA.count == bufferB.count else { return 1.0 }
        var diffCount = 0
        for i in 0..<bufferA.count {
            let diff = abs(Int(bufferA[i]) - Int(bufferB[i]))
            if diff > 16 { // Perceptual noise threshold
                diffCount += 1
            }
        }
        return Double(diffCount) / Double(bufferA.count)
    }
}
