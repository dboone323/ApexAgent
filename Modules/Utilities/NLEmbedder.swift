import Foundation
import NaturalLanguage
import SharedModels

public actor NLEmbedder {
    private let embeddingModel: NLEmbedding?

    public init() {
        self.embeddingModel = NLEmbedding.sentenceEmbedding(for: .english)
    }

    public func embed(_ text: String) async throws -> [Double] {
        guard let model = embeddingModel else {
            throw NSError(domain: "NLEmbedder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sentence embedding model not available"])
        }
        guard let vector = model.vector(for: text) else {
            throw NSError(domain: "NLEmbedder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to generate embedding vector"])
        }
        return vector.map { Double($0) }
    }

    nonisolated public func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0.0 }
        var dotProduct = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0.0, normB > 0.0 else { return 0.0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }

    nonisolated public func findMostSimilar(
        query: String,
        in entries: [AgentMemoryEntry],
        topK: Int = 5
    ) async throws -> [AgentMemoryEntry] {
        let queryVector = try await embed(query)

        var scoredEntries: [(entry: AgentMemoryEntry, score: Double)] = []
        for entry in entries {
            guard let entryVector = try? JSONDecoder().decode([Double].self, from: entry.embedding) else { continue }
            let score = cosineSimilarity(queryVector, entryVector)
            scoredEntries.append((entry, score))
        }

        let sorted = scoredEntries.sorted(by: { $0.score > $1.score })
        return sorted.prefix(topK).map { $0.entry }
    }
}
