import Foundation
import FoundationModels
import SwiftData
import NaturalLanguage

// MARK: - Embedding Helper

@MainActor
class EmbeddingHelper {
    static func getVector(for text: String) -> [Double]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return nil
        }
        return embedding.vector(for: text)
    }
    
    static func serialize(_ vector: [Double]) -> Data? {
        return try? JSONEncoder().encode(vector)
    }
    
    static func deserialize(_ data: Data) -> [Double]? {
        return try? JSONDecoder().decode([Double].self, from: data)
    }
    
    static func cosineSimilarity(v1: [Double], v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0.0 }
        var dotProduct = 0.0
        var magnitude1 = 0.0
        var magnitude2 = 0.0
        for i in 0..<v1.count {
            dotProduct += v1[i] * v2[i]
            magnitude1 += v1[i] * v1[i]
            magnitude2 += v2[i] * v2[i]
        }
        guard magnitude1 > 0 && magnitude2 > 0 else { return 0.0 }
        return dotProduct / (sqrt(magnitude1) * sqrt(magnitude2))
    }
}

// MARK: - Store Memory Tool

struct StoreMemoryTool: Tool {
    let name = "store_memory"
    let description = "Stores or updates a key-value memory record in the on-device SQLite database. Use this to remember important system locations, file changes, or status of long-running tasks."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The topic or identifier for this memory (e.g., 'task_status', 'project_root')")
        var key: String
        
        @Guide(description: "The detailed value/notes to remember")
        var value: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            return await MainActor.run {
                guard let context = AgentOrchestrator.shared?.modelContext else {
                    return "ERROR: Database context not available"
                }

                let keyToFind = arguments.key.trimmingCharacters(in: .whitespacesAndNewlines)
                var descriptor = FetchDescriptor<AgentMemory>(
                    predicate: #Predicate { $0.key == keyToFind }
                )
                descriptor.fetchLimit = 1
                
                do {
                    let existing = try context.fetch(descriptor)
                    let textToEmbed = "\(keyToFind): \(arguments.value)"
                    let vector = EmbeddingHelper.getVector(for: textToEmbed)
                    let embeddingData = vector.flatMap { EmbeddingHelper.serialize($0) }
                    
                    if let memory = existing.first {
                        memory.val = arguments.value
                        memory.timestamp = Date()
                        memory.embeddingData = embeddingData
                    } else {
                        let newMemory = AgentMemory(key: keyToFind, val: arguments.value)
                        newMemory.embeddingData = embeddingData
                        context.insert(newMemory)
                    }
                    try context.save()
                    return "✅ Successfully saved memory for key: '\(keyToFind)'"
                } catch {
                    return "ERROR: Failed to save to database: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Search Memory Tool

struct SearchMemoryTool: Tool {
    let name = "search_memory"
    let description = "Searches the long-term SQLite memory database for entries matching the query keyword."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Search keyword to match against keys or values. If empty, lists the most recent memories.")
        var query: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            return await MainActor.run {
                guard let context = AgentOrchestrator.shared?.modelContext else {
                    return "ERROR: Database context not available"
                }

                var descriptor = FetchDescriptor<AgentMemory>(
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                
                do {
                    let allMemories = try context.fetch(descriptor)
                    
                    let filtered: [AgentMemory]
                    if let query = arguments.query?.lowercased().trimTime(), !query.isEmpty {
                        filtered = allMemories.filter {
                            $0.key.lowercased().contains(query) || $0.val.lowercased().contains(query)
                        }
                    } else {
                        filtered = Array(allMemories.prefix(20))
                    }
                    
                    if filtered.isEmpty {
                        return "No memory records found."
                    }
                    
                    var output = "🧠 Found \(filtered.count) memory records:\n"
                    for memory in filtered {
                        output += "\n--- \(memory.key) (\(memory.timestamp.formatted())) ---\n\(memory.val)\n"
                    }
                    return output
                } catch {
                    return "ERROR: Failed to query database: \(error.localizedDescription)"
                }
            }
        }
    }
}

private extension String {
    func trimTime() -> String {
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
