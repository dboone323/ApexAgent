import Foundation
import CoreGraphics

// MARK: - Differential Screen Perception Thresholds & Visual Change Gate (Batch 92)

/// Configuration policy for screen visual diffing and significant change detection.
public struct PerceptionDiffPolicy: Sendable, Codable, Equatable {
    /// Minimum percentage of changed pixels (0.0 to 100.0) required to consider screen state modified.
    public var changeThresholdPercent: Double
    /// Maximum Hamming distance on 64-bit dHash before declaring visual state change (e.g. 5).
    public var hammingDistanceThreshold: Int
    /// Minimum bounding box dimension (width or height) to consider valid UI element update.
    public var minBoundingBoxDimension: Double

    public init(
        changeThresholdPercent: Double = 0.5,
        hammingDistanceThreshold: Int = 4,
        minBoundingBoxDimension: Double = 8.0
    ) {
        self.changeThresholdPercent = changeThresholdPercent
        self.hammingDistanceThreshold = hammingDistanceThreshold
        self.minBoundingBoxDimension = minBoundingBoxDimension
    }
}

/// Evaluation outcome from analyzing differential screen pixels.
public struct VisualChangeEvaluation: Sendable, Codable, Equatable {
    public let isSignificantChange: Bool
    public let changedPixelPercentage: Double
    public let hammingDistance: Int
    public let dirtyBoundingBoxes: [CGRect]

    public init(
        isSignificantChange: Bool,
        changedPixelPercentage: Double,
        hammingDistance: Int,
        dirtyBoundingBoxes: [CGRect]
    ) {
        self.isSignificantChange = isSignificantChange
        self.changedPixelPercentage = changedPixelPercentage
        self.hammingDistance = hammingDistance
        self.dirtyBoundingBoxes = dirtyBoundingBoxes
    }
}

/// Violation detected during visual perception analysis.
public struct VisualPerceptionViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit report produced by comparing screen frames for perceptual changes.
public struct VisualPerceptionAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluation: VisualChangeEvaluation
    public let violations: [VisualPerceptionViolation]

    public init(
        passed: Bool,
        score: Double,
        evaluation: VisualChangeEvaluation,
        violations: [VisualPerceptionViolation]
    ) {
        self.passed = passed
        self.score = score
        self.evaluation = evaluation
        self.violations = violations
    }
}

/// Auditor for screen perception change thresholds, difference hash (dHash), and dirty region bounding boxes.
public enum VisualPerceptionAuditor {

    // MARK: - Perceptual Difference Hash (dHash)

    /// Computes a 64-bit difference hash (dHash) from an 8x8 or 9x8 grayscale image buffer.
    /// Each bit compares pixel[x] > pixel[x+1] across 8 rows.
    public static func computeDHash(grayscale8x9: [UInt8]) -> UInt64 {
        guard grayscale8x9.count >= 72 else { return 0 }
        var hash: UInt64 = 0

        for row in 0..<8 {
            for col in 0..<8 {
                let left = grayscale8x9[row * 9 + col]
                let right = grayscale8x9[row * 9 + col + 1]
                if left > right {
                    hash |= (1 &<< (row * 8 + col))
                }
            }
        }
        return hash
    }

    /// Computes Hamming distance between two 64-bit hashes using population count.
    public static func computeHammingDistance(_ h1: UInt64, _ h2: UInt64) -> Int {
        return (h1 ^ h2).nonzeroBitCount
    }

    // MARK: - Pixel Buffer Difference Evaluation

    /// Audits two grayscale pixel buffers and determines if the delta exceeds perception thresholds.
    public static func evaluatePixelDifference(
        bufferA: [UInt8],
        bufferB: [UInt8],
        width: Int,
        height: Int,
        policy: PerceptionDiffPolicy = PerceptionDiffPolicy()
    ) -> VisualPerceptionAuditReport {
        var violations: [VisualPerceptionViolation] = []

        let totalPixels = width * height

        // 1. Buffer size validation
        if width <= 0 || height <= 0 {
            violations.append(VisualPerceptionViolation(
                code: "INVALID_IMAGE_DIMENSIONS",
                message: "Image dimensions must be positive integers (\(width)x\(height))."
            ))
            let emptyEval = VisualChangeEvaluation(
                isSignificantChange: false,
                changedPixelPercentage: 0.0,
                hammingDistance: 0,
                dirtyBoundingBoxes: []
            )
            return VisualPerceptionAuditReport(passed: false, score: 0.0, evaluation: emptyEval, violations: violations)
        }

        if bufferA.count != totalPixels || bufferB.count != totalPixels {
            violations.append(VisualPerceptionViolation(
                code: "BUFFER_SIZE_MISMATCH",
                message: "Pixel buffer size does not match expected \(totalPixels) bytes (A: \(bufferA.count), B: \(bufferB.count))."
            ))
            let emptyEval = VisualChangeEvaluation(
                isSignificantChange: false,
                changedPixelPercentage: 0.0,
                hammingDistance: 0,
                dirtyBoundingBoxes: []
            )
            return VisualPerceptionAuditReport(passed: false, score: 0.0, evaluation: emptyEval, violations: violations)
        }

        // 2. Count changed pixels and find dirty bounding box
        var changedCount = 0
        var minX = width
        var maxX = 0
        var minY = height
        var maxY = 0

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let diff = abs(Int(bufferA[idx]) - Int(bufferB[idx]))
                // Grayscale difference threshold: 16 intensity levels
                if diff > 16 {
                    changedCount += 1
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }

        let changePercentage = (Double(changedCount) / Double(totalPixels)) * 100.0

        // 3. Compute dirty bounding box
        var dirtyBoxes: [CGRect] = []
        if changedCount > 0 && minX <= maxX && minY <= maxY {
            let boxWidth = Double(maxX - minX + 1)
            let boxHeight = Double(maxY - minY + 1)
            if boxWidth >= policy.minBoundingBoxDimension || boxHeight >= policy.minBoundingBoxDimension {
                dirtyBoxes.append(CGRect(x: Double(minX), y: Double(minY), width: boxWidth, height: boxHeight))
            }
        }

        // 4. Perceptual downsampling to 9x8 for dHash
        let dHashA = downsampleToDHash(buffer: bufferA, width: width, height: height)
        let dHashB = downsampleToDHash(buffer: bufferB, width: width, height: height)
        let hammingDistance = computeHammingDistance(dHashA, dHashB)

        // 5. Significant change decision
        let isSignificant = (changePercentage >= policy.changeThresholdPercent) ||
                            (hammingDistance >= policy.hammingDistanceThreshold)

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? 100.0 : 0.0

        let evaluation = VisualChangeEvaluation(
            isSignificantChange: isSignificant,
            changedPixelPercentage: changePercentage,
            hammingDistance: hammingDistance,
            dirtyBoundingBoxes: dirtyBoxes
        )

        return VisualPerceptionAuditReport(
            passed: passed,
            score: score,
            evaluation: evaluation,
            violations: violations
        )
    }

    /// Internal helper: downsamples a width x height grayscale buffer to 9x8 and computes dHash.
    private static func downsampleToDHash(buffer: [UInt8], width: Int, height: Int) -> UInt64 {
        var grid = [UInt8](repeating: 0, count: 72)
        let blockW = max(1, width / 9)
        let blockH = max(1, height / 8)

        for row in 0..<8 {
            for col in 0..<9 {
                var sum = 0
                var samples = 0
                for y in (row * blockH)..<min(height, (row + 1) * blockH) {
                    for x in (col * blockW)..<min(width, (col + 1) * blockW) {
                        sum += Int(buffer[y * width + x])
                        samples += 1
                    }
                }
                grid[row * 9 + col] = UInt8(samples > 0 ? sum / samples : 0)
            }
        }

        return computeDHash(grayscale8x9: grid)
    }
}
