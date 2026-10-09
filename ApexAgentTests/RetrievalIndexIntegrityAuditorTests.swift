import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 84 — Local Retrieval Index Embedding Parity & Chunking Gate Tests")
struct RetrievalIndexIntegrityAuditorTests {

    @Test("L2 norm calculation accurately computes Euclidean length using vDSP")
    func l2NormAccurate() {
        // [3.0, 4.0] -> sqrt(9 + 16) = 5.0
        let norm2D = RetrievalIndexIntegrityAuditor.computeL2Norm([3.0, 4.0])
        #expect(abs(norm2D - 5.0) < 0.001)

        // Unit vector [0, 1, 0] -> 1.0
        let normUnit = RetrievalIndexIntegrityAuditor.computeL2Norm([0.0, 1.0, 0.0])
        #expect(abs(normUnit - 1.0) < 0.001)
    }

    @Test("Cosine similarity computes accurate dot product normalized similarity")
    func cosineSimilarityAccurate() {
        let v1: [Float] = [1.0, 0.0, 0.0]
        let v2: [Float] = [1.0, 0.0, 0.0]
        let v3: [Float] = [0.0, 1.0, 0.0]
        let v4: [Float] = [-1.0, 0.0, 0.0]

        // Identical: 1.0
        let simIdentical = RetrievalIndexIntegrityAuditor.cosineSimilarity(v1, v2)
        #expect(simIdentical != nil)
        #expect(abs((simIdentical ?? 0.0) - 1.0) < 0.001)

        // Orthogonal: 0.0
        let simOrthogonal = RetrievalIndexIntegrityAuditor.cosineSimilarity(v1, v3)
        #expect(simOrthogonal != nil)
        #expect(abs(simOrthogonal ?? 1.0) < 0.001)

        // Opposite: -1.0
        let simOpposite = RetrievalIndexIntegrityAuditor.cosineSimilarity(v1, v4)
        #expect(simOpposite != nil)
        #expect(abs((simOpposite ?? 0.0) - (-1.0)) < 0.001)

        // Dimension mismatch returns nil
        let simMismatch = RetrievalIndexIntegrityAuditor.cosineSimilarity([1.0, 2.0], [1.0])
        #expect(simMismatch == nil)

        // Zero vector returns nil
        let simZero = RetrievalIndexIntegrityAuditor.cosineSimilarity([0.0, 0.0], [1.0, 1.0])
        #expect(simZero == nil)
    }

    @Test("Text chunking correctly windows text with overlap")
    func textChunkingValid() {
        let text = "The quick brown fox jumps over the lazy dog. Swift 6.4 and macOS 27 deliver high performance agentic coding."
        let report = RetrievalIndexIntegrityAuditor.auditChunking(text: text, chunkSize: 30, overlap: 10)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.totalChunksCount > 1)
        #expect(report.averageChunkSize > 0.0)
        #expect(report.overlapValid)
        #expect(report.violations.isEmpty)
    }

    @Test("Chunking overlap equal or larger than chunk size triggers violation")
    func chunkingOverlapExceedsSize() {
        let report = RetrievalIndexIntegrityAuditor.auditChunking(text: "Hello world", chunkSize: 50, overlap: 60)

        #expect(!report.passed)
        #expect(report.score == 0.0)
        #expect(!report.overlapValid)
        #expect(report.violations.contains { $0.code == "OVERLAP_EXCEEDS_CHUNK_SIZE" })
    }

    @Test("Valid index audit passes with 100% score and unit norm detection")
    func validIndexAuditPasses() {
        // Create unit vector of dim 4: [0.5, 0.5, 0.5, 0.5] -> norm = sqrt(4 * 0.25) = 1.0
        let vector: [Float] = [0.5, 0.5, 0.5, 0.5]
        let entries = [
            IndexAuditEntry(id: "doc-1", documentTitle: "Doc 1", textChunk: "Content 1", embedding: vector),
            IndexAuditEntry(id: "doc-2", documentTitle: "Doc 2", textChunk: "Content 2", embedding: vector)
        ]

        let report = RetrievalIndexIntegrityAuditor.auditIndex(entries: entries, expectedDimension: 4)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.totalEntriesCount == 2)
        #expect(report.declaredDimension == 4)
        #expect(report.dimensionConsistent)
        #expect(report.normalizedVectorsCount == 2)
        #expect(report.violations.isEmpty)
    }

    @Test("Index with dimension mismatch and NaN values reports fatal violations")
    func invalidIndexAuditFails() {
        let entries = [
            IndexAuditEntry(id: "doc-bad-dim", documentTitle: "Doc Bad", textChunk: "Wrong", embedding: [0.5, 0.5]),
            IndexAuditEntry(id: "doc-nan", documentTitle: "Doc NaN", textChunk: "Corrupt", embedding: [Float.nan, 0.5, 0.5, 0.5])
        ]

        let report = RetrievalIndexIntegrityAuditor.auditIndex(entries: entries, expectedDimension: 4)

        #expect(!report.passed)
        #expect(report.score < 100.0)
        #expect(!report.dimensionConsistent)
        #expect(report.violations.contains { $0.code == "DIMENSION_MISMATCH" })
        #expect(report.violations.contains { $0.code == "INVALID_VECTOR_VALUES" })
    }

    @Test("Empty index returns fatal EMPTY_RETRIEVAL_INDEX violation")
    func emptyIndexAuditFails() {
        let report = RetrievalIndexIntegrityAuditor.auditIndex(entries: [], expectedDimension: 128)

        #expect(!report.passed)
        #expect(report.score == 0.0)
        #expect(report.violations.contains { $0.code == "EMPTY_RETRIEVAL_INDEX" })
    }
}
