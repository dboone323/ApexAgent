import Foundation
import Accelerate

// MARK: - Local Retrieval Index Embedding Parity & Chunking Gate (Batch 84)

/// Entry in a local vector retrieval index for integrity auditing.
public struct IndexAuditEntry: Sendable, Codable, Equatable {
    public let id: String
    public let documentTitle: String
    public let textChunk: String
    public let embedding: [Float]

    public init(id: String, documentTitle: String, textChunk: String, embedding: [Float]) {
        self.id = id
        self.documentTitle = documentTitle
        self.textChunk = textChunk
        self.embedding = embedding
    }
}

/// Violation detected during retrieval index audit.
public struct RetrievalIndexViolation: Sendable, Codable, Equatable {
    public let entryId: String?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(entryId: String? = nil, code: String, message: String, isFatal: Bool = true) {
        self.entryId = entryId
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by auditing text chunking parameters and chunk continuity.
public struct ChunkingAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalChunksCount: Int
    public let averageChunkSize: Double
    public let overlapValid: Bool
    public let violations: [RetrievalIndexViolation]

    public init(
        passed: Bool,
        score: Double,
        totalChunksCount: Int,
        averageChunkSize: Double,
        overlapValid: Bool,
        violations: [RetrievalIndexViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalChunksCount = totalChunksCount
        self.averageChunkSize = averageChunkSize
        self.overlapValid = overlapValid
        self.violations = violations
    }
}

/// Complete report produced by auditing a vector retrieval index.
public struct RetrievalIndexAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalEntriesCount: Int
    public let declaredDimension: Int
    public let dimensionConsistent: Bool
    public let normalizedVectorsCount: Int
    public let violations: [RetrievalIndexViolation]

    public init(
        passed: Bool,
        score: Double,
        totalEntriesCount: Int,
        declaredDimension: Int,
        dimensionConsistent: Bool,
        normalizedVectorsCount: Int,
        violations: [RetrievalIndexViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalEntriesCount = totalEntriesCount
        self.declaredDimension = declaredDimension
        self.dimensionConsistent = dimensionConsistent
        self.normalizedVectorsCount = normalizedVectorsCount
        self.violations = violations
    }
}

/// Auditor for local retrieval embeddings, vector norms, chunking overlap, and cosine similarity.
public enum RetrievalIndexIntegrityAuditor {

    // MARK: - Vector Mathematics

    /// Computes Euclidean L2 norm of a vector: sqrt(sum(v_i^2)).
    public static func computeL2Norm(_ vector: [Float]) -> Float {
        var sumSquares: Float = 0.0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        return sqrt(sumSquares)
    }

    /// Computes cosine similarity between two vectors: (u · v) / (||u|| * ||v||).
    public static func cosineSimilarity(_ u: [Float], _ v: [Float]) -> Float? {
        guard u.count == v.count && !u.isEmpty else { return nil }

        var dotProduct: Float = 0.0
        vDSP_dotpr(u, 1, v, 1, &dotProduct, vDSP_Length(u.count))

        let normU = computeL2Norm(u)
        let normV = computeL2Norm(v)

        guard normU > 0.00001 && normV > 0.00001 else { return nil }
        let similarity = dotProduct / (normU * normV)
        return max(-1.0, min(1.0, similarity))
    }

    // MARK: - Chunking Audit

    /// Audits chunking of source text into windows and verifies overlap integrity.
    public static func auditChunking(
        text: String,
        chunkSize: Int = 500,
        overlap: Int = 100
    ) -> ChunkingAuditReport {
        var violations: [RetrievalIndexViolation] = []

        if overlap >= chunkSize {
            violations.append(RetrievalIndexViolation(
                code: "OVERLAP_EXCEEDS_CHUNK_SIZE",
                message: "Overlap of \(overlap) chars is greater than or equal to chunk size \(chunkSize)."
            ))
        }

        if text.isEmpty {
            return ChunkingAuditReport(
                passed: violations.isEmpty,
                score: violations.isEmpty ? 100.0 : 0.0,
                totalChunksCount: 0,
                averageChunkSize: 0.0,
                overlapValid: violations.isEmpty,
                violations: violations
            )
        }

        // Generate chunks
        var chunks: [String] = []
        let step = max(1, chunkSize - overlap)
        var startIndex = text.startIndex

        while startIndex < text.endIndex {
            let endIndex = text.index(startIndex, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[startIndex..<endIndex]))
            if endIndex == text.endIndex { break }
            startIndex = text.index(startIndex, offsetBy: step, limitedBy: text.endIndex) ?? text.endIndex
        }

        let totalLength = chunks.reduce(0) { $0 + $1.count }
        let avgSize = chunks.isEmpty ? 0.0 : Double(totalLength) / Double(chunks.count)

        let passed = violations.isEmpty
        let score = passed ? 100.0 : 0.0

        return ChunkingAuditReport(
            passed: passed,
            score: score,
            totalChunksCount: chunks.count,
            averageChunkSize: avgSize,
            overlapValid: violations.isEmpty,
            violations: violations
        )
    }

    // MARK: - Index Audit

    /// Audits an index collection for dimensionality consistency, NaN/Inf checks, and unit norm validity.
    public static func auditIndex(
        entries: [IndexAuditEntry],
        expectedDimension: Int
    ) -> RetrievalIndexAuditReport {
        var violations: [RetrievalIndexViolation] = []
        var dimensionConsistent = true
        var normalizedCount = 0

        guard !entries.isEmpty else {
            violations.append(RetrievalIndexViolation(
                code: "EMPTY_RETRIEVAL_INDEX",
                message: "Index contains zero entries."
            ))
            return RetrievalIndexAuditReport(
                passed: false,
                score: 0.0,
                totalEntriesCount: 0,
                declaredDimension: expectedDimension,
                dimensionConsistent: false,
                normalizedVectorsCount: 0,
                violations: violations
            )
        }

        for entry in entries {
            // 1. Dimensionality check
            if entry.embedding.count != expectedDimension {
                dimensionConsistent = false
                violations.append(RetrievalIndexViolation(
                    entryId: entry.id,
                    code: "DIMENSION_MISMATCH",
                    message: "Entry '\(entry.id)' has dimension \(entry.embedding.count); expected \(expectedDimension)."
                ))
            }

            // 2. NaN / Infinite check
            if entry.embedding.contains(where: { $0.isNaN || $0.isInfinite }) {
                violations.append(RetrievalIndexViolation(
                    entryId: entry.id,
                    code: "INVALID_VECTOR_VALUES",
                    message: "Entry '\(entry.id)' embedding contains NaN or infinite floats."
                ))
            }

            // 3. Norm check (near unit norm)
            let norm = computeL2Norm(entry.embedding)
            if abs(norm - 1.0) < 0.05 {
                normalizedCount += 1
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return RetrievalIndexAuditReport(
            passed: passed,
            score: score,
            totalEntriesCount: entries.count,
            declaredDimension: expectedDimension,
            dimensionConsistent: dimensionConsistent,
            normalizedVectorsCount: normalizedCount,
            violations: violations
        )
    }
}
