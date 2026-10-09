import Foundation
import CoreGraphics

// MARK: - Ghost Cursor & Screen Highlight Overlay Coordinate Clamp Gate (Batch 86)

/// Coordinate system origin conventions used across macOS and computer vision.
public enum OverlayCoordinateOrigin: String, Sendable, Codable, Equatable {
    /// Standard Cocoa / AppKit coordinate origin (bottom-left of primary screen).
    case bottomLeft
    /// Standard Quartz / CG / Vision / Browser coordinate origin (top-left of screen).
    case topLeft
}

/// Clamped and validated rectangle result with clipping telemetry.
public struct ClampedOverlayRect: Sendable, Codable, Equatable {
    public let original: CGRect
    public let clamped: CGRect
    public let wasClamped: Bool
    public let screenBounds: CGRect
    public let scaleFactor: CGFloat

    public init(
        original: CGRect,
        clamped: CGRect,
        wasClamped: Bool,
        screenBounds: CGRect,
        scaleFactor: CGFloat = 2.0
    ) {
        self.original = original
        self.clamped = clamped
        self.wasClamped = wasClamped
        self.screenBounds = screenBounds
        self.scaleFactor = scaleFactor
    }
}

/// Violation detected during overlay geometry audit.
public struct OverlayGeometryViolation: Sendable, Codable, Equatable {
    public let rectIndex: Int?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(rectIndex: Int? = nil, code: String, message: String, isFatal: Bool = true) {
        self.rectIndex = rectIndex
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit report produced by evaluating screen overlay bounds, scaling, and geometry sanity.
public struct OverlayGeometryAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalRectsCount: Int
    public let clampedRects: [ClampedOverlayRect]
    public let violations: [OverlayGeometryViolation]

    public init(
        passed: Bool,
        score: Double,
        totalRectsCount: Int,
        clampedRects: [ClampedOverlayRect],
        violations: [OverlayGeometryViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalRectsCount = totalRectsCount
        self.clampedRects = clampedRects
        self.violations = violations
    }
}

/// Auditor for screen overlay coordinates, multi-monitor bounds clamping, and coordinate system translation.
public enum OverlayGeometryAuditor {

    // MARK: - Coordinate Translation

    /// Converts a point between top-left and bottom-left coordinate systems.
    public static func convertPointOrigin(
        _ point: CGPoint,
        screenHeight: CGFloat,
        from source: OverlayCoordinateOrigin,
        to destination: OverlayCoordinateOrigin
    ) -> CGPoint {
        guard source != destination else { return point }
        // y_flipped = screenHeight - y
        return CGPoint(x: point.x, y: max(0.0, screenHeight - point.y))
    }

    /// Converts a CGRect between top-left and bottom-left coordinate systems.
    public static func convertRectOrigin(
        _ rect: CGRect,
        screenHeight: CGFloat,
        from source: OverlayCoordinateOrigin,
        to destination: OverlayCoordinateOrigin
    ) -> CGRect {
        guard source != destination else { return rect }
        // When flipping rect from top-left to bottom-left (or vice versa):
        // new_y = screenHeight - rect.origin.y - rect.height
        let newY = max(0.0, screenHeight - rect.origin.y - rect.height)
        return CGRect(x: rect.origin.x, y: newY, width: rect.width, height: rect.height)
    }

    // MARK: - Coordinate Clamping

    /// Clamps a cursor point to strictly lie within target screen bounds.
    public static func clampPoint(
        _ point: CGPoint,
        to screenBounds: CGRect
    ) -> (clamped: CGPoint, wasClamped: Bool) {
        let clampedX = min(max(point.x, screenBounds.minX), screenBounds.maxX)
        let clampedY = min(max(point.y, screenBounds.minY), screenBounds.maxY)
        let wasClamped = (clampedX != point.x) || (clampedY != point.y)
        return (CGPoint(x: clampedX, y: clampedY), wasClamped)
    }

    /// Clamps a highlight rectangle to strictly fit within target screen bounds.
    public static func clampRect(
        _ rect: CGRect,
        to screenBounds: CGRect,
        minDimension: CGFloat = 4.0,
        scaleFactor: CGFloat = 2.0
    ) -> ClampedOverlayRect {
        // Intersect rect with screen bounds
        let intersection = rect.intersection(screenBounds)

        if intersection.isNull || intersection.isEmpty {
            // Entirely offscreen: clamp origin to screen edge and set minimum size
            let safeX = min(max(rect.origin.x, screenBounds.minX), screenBounds.maxX - minDimension)
            let safeY = min(max(rect.origin.y, screenBounds.minY), screenBounds.maxY - minDimension)
            let clamped = CGRect(x: safeX, y: safeY, width: minDimension, height: minDimension)
            return ClampedOverlayRect(
                original: rect,
                clamped: clamped,
                wasClamped: true,
                screenBounds: screenBounds,
                scaleFactor: scaleFactor
            )
        }

        let clampedWidth = max(minDimension, intersection.width)
        let clampedHeight = max(minDimension, intersection.height)
        let clampedRect = CGRect(
            x: intersection.origin.x,
            y: intersection.origin.y,
            width: clampedWidth,
            height: clampedHeight
        )

        let wasClamped = (clampedRect != rect)
        return ClampedOverlayRect(
            original: rect,
            clamped: clampedRect,
            wasClamped: wasClamped,
            screenBounds: screenBounds,
            scaleFactor: scaleFactor
        )
    }

    // MARK: - Highlighting Audit

    /// Audits a batch of highlight rects for count limits, NaN values, zero/negative sizes, and offscreen containment.
    public static func auditHighlightRects(
        rects: [CGRect],
        screenBounds: CGRect,
        maxRectsCount: Int = 50,
        scaleFactor: CGFloat = 2.0
    ) -> OverlayGeometryAuditReport {
        var violations: [OverlayGeometryViolation] = []
        var clampedResults: [ClampedOverlayRect] = []

        // 1. Empty check
        if rects.isEmpty {
            violations.append(OverlayGeometryViolation(
                code: "EMPTY_OVERLAY_RECTS",
                message: "No overlay rectangles provided for highlighting audit."
            ))
            return OverlayGeometryAuditReport(
                passed: false,
                score: 0.0,
                totalRectsCount: 0,
                clampedRects: [],
                violations: violations
            )
        }

        // 2. Count limit check
        if rects.count > maxRectsCount {
            violations.append(OverlayGeometryViolation(
                code: "OVERLAY_RECTS_LIMIT_EXCEEDED",
                message: "Requested \(rects.count) overlay rectangles, exceeding ceiling of \(maxRectsCount)."
            ))
        }

        // 3. Screen bounds validation
        if screenBounds.width <= 0 || screenBounds.height <= 0 || screenBounds.isNull {
            violations.append(OverlayGeometryViolation(
                code: "INVALID_SCREEN_BOUNDS",
                message: "Target screen bounds are empty or invalid: \(screenBounds)."
            ))
        }

        // 4. Validate each rect
        for (index, rect) in rects.enumerated() {
            // NaN / Inf checks
            if rect.origin.x.isNaN || rect.origin.y.isNaN || rect.width.isNaN || rect.height.isNaN ||
               rect.origin.x.isInfinite || rect.origin.y.isInfinite || rect.width.isInfinite || rect.height.isInfinite {
                violations.append(OverlayGeometryViolation(
                    rectIndex: index,
                    code: "NAN_OR_INF_COORDINATES",
                    message: "Rect at index \(index) contains NaN or infinite values."
                ))
                continue
            }

            // Negative or zero dimension check
            if rect.size.width <= 0 || rect.size.height <= 0 {
                violations.append(OverlayGeometryViolation(
                    rectIndex: index,
                    code: "NON_POSITIVE_DIMENSIONS",
                    message: "Rect at index \(index) has non-positive dimensions (\(rect.size.width)x\(rect.size.height))."
                ))
                continue
            }

            // Offscreen check
            let clamped = clampRect(rect, to: screenBounds, scaleFactor: scaleFactor)
            clampedResults.append(clamped)

            if !screenBounds.intersects(rect) {
                violations.append(OverlayGeometryViolation(
                    rectIndex: index,
                    code: "ENTIRELY_OFFSCREEN",
                    message: "Rect at index \(index) (\(rect)) is entirely outside screen bounds (\(screenBounds))."
                ))
            } else if clamped.wasClamped {
                violations.append(OverlayGeometryViolation(
                    rectIndex: index,
                    code: "PARTIALLY_OFFSCREEN",
                    message: "Rect at index \(index) extends beyond screen bounds and was clamped.",
                    isFatal: false
                ))
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 5.0
        score = max(0.0, min(100.0, score))

        return OverlayGeometryAuditReport(
            passed: passed,
            score: score,
            totalRectsCount: rects.count,
            clampedRects: clampedResults,
            violations: violations
        )
    }
}
