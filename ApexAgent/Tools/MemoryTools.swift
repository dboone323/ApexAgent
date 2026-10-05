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
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "store_memory"
    let description = "Stores or updates a key-value memory record in the on-device SQLite database. Use this to remember important system locations, file changes, or status of long-running tasks."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The topic or identifier for this memory (e.g., 'task_status', 'project_root')")
        var key: String
        
        @Guide(description: "The detailed value/notes to remember")
        var value: String

        @Guide(description: "The category/profile type for this memory (e.g., 'user_preference', 'codebase_insight', 'execution_history')")
        var category: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return await MainActor.run {
                guard let context = orchestrator.orchestrator.modelContext else {
                    return "Memory unavailable: model context is not initialized."
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
                    
                    let cat = arguments.category ?? "general"
                    if let memory = existing.first {
                        memory.val = arguments.value
                        memory.category = cat
                        memory.timestamp = Date()
                        memory.embeddingData = embeddingData
                    } else {
                        let newMemory = AgentMemory(key: keyToFind, val: arguments.value, category: cat)
                        newMemory.embeddingData = embeddingData
                        context.insert(newMemory)
                    }
                    try context.save()

                    // Mirror to CognitiveMemoryEngine so semantic graph stays synchronized
                    let targetBotId = orchestrator.orchestrator.botManager?.allBots.first?.id ?? UUID()
                    CognitiveMemoryEngine.shared.storeBotFact(
                        botId: targetBotId,
                        subject: keyToFind,
                        predicate: "is",
                        object: arguments.value,
                        source: cat
                    )

                    return "✅ Successfully saved memory for key: '\(keyToFind)' in category: '\(cat)'"
                } catch {
                    return "ERROR: Failed to save to database: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Search Memory Tool

struct SearchMemoryTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "search_memory"
    let description = "Searches the long-term SQLite memory database for entries matching the query keyword."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Search keyword to match against keys or values. If empty, lists the most recent memories.")
        var query: String?

        @Guide(description: "Optional category filter to search only memories under a specific profile type.")
        var category: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return await MainActor.run {
                guard let context = orchestrator.orchestrator.modelContext else {
                    return "Memory unavailable: model context is not initialized."
                }

                let descriptor = FetchDescriptor<AgentMemory>(
                    sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
                )
                
                do {
                    let allMemories = try context.fetch(descriptor)
                    
                    var filtered = allMemories
                    if let category = arguments.category?.lowercased().trimTime(), !category.isEmpty {
                        filtered = filtered.filter { $0.category.lowercased() == category }
                    }
                    if let query = arguments.query?.lowercased().trimTime(), !query.isEmpty {
                        let normalizedQuery = query.replacingOccurrences(of: "_", with: " ")
                        let queryTokens = normalizedQuery
                            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
                            .filter { $0.count >= 2 }
                        filtered = filtered.filter { memory in
                            let keyLower = memory.key.lowercased()
                            let valLower = memory.val.lowercased()
                            if keyLower.contains(query) || valLower.contains(query) {
                                return true
                            }
                            let combined = (keyLower.replacingOccurrences(of: "_", with: " ") + " " + valLower)
                            guard !queryTokens.isEmpty else { return false }
                            let matchedCount = queryTokens.filter { combined.contains($0) }.count
                            return matchedCount == queryTokens.count
                                || (queryTokens.count >= 3 && Double(matchedCount) / Double(queryTokens.count) >= 0.75)
                        }
                    } else if arguments.category == nil || arguments.category?.trimTime().isEmpty == true {
                        filtered = Array(filtered.prefix(20))
                    }
                    
                    var output = ""
                    if !filtered.isEmpty {
                        output += "🧠 Found \(filtered.count) memory records:\n"
                        for memory in filtered {
                            output += "\n--- \(memory.key) [Category: \(memory.category)] (\(memory.timestamp.formatted())) ---\n\(memory.val)\n"
                        }
                    }

                    if let query = arguments.query?.trimTime(), !query.isEmpty {
                        let cognitiveContext = CognitiveMemoryEngine.shared.retrieveRelevantContext(query: query)
                        if !cognitiveContext.hasPrefix("No indexed cognitive memory") {
                            if !output.isEmpty { output += "\n\n" }
                            output += cognitiveContext
                        }
                    }

                    if output.isEmpty {
                        return "No memory records found."
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
