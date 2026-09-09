import Foundation
import Observation

@Observable
@MainActor
public final class CognitiveMemoryEngine {
    public static let shared = CognitiveMemoryEngine()
    
    private init() {}
    
    // MARK: - Working Memory (ephemeral, scoped per bot-turn)
    private var workingMemory: [UUID: String] = [:]
    
    public func setWorkingContext(_ text: String, forBotId botId: UUID) {
        workingMemory[botId] = text
    }
    
    public func getWorkingContext(forBotId botId: UUID) -> String {
        return workingMemory[botId] ?? ""
    }
    
    public func clearWorkingContext(forBotId botId: UUID) {
        workingMemory.removeValue(forKey: botId)
    }
    
    // MARK: - Episodic Memory (timestamped events)
    public struct EpisodicEntry: Identifiable, Codable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let botId: UUID
        public let eventType: String
        public let summary: String
        public let metadata: [String: String]
        
        public init(id: UUID = UUID(), timestamp: Date = Date(), botId: UUID, eventType: String, summary: String, metadata: [String: String] = [:]) {
            self.id = id
            self.timestamp = timestamp
            self.botId = botId
            self.eventType = eventType
            self.summary = summary
            self.metadata = metadata
        }
    }
    
    private func getMemoryDirectory(forBotId botId: UUID) -> URL {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let apexDir = homeDir.appendingPathComponent(".apex/memory/\(botId.uuidString)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: apexDir.path) {
            try? FileManager.default.createDirectory(at: apexDir, withIntermediateDirectories: true)
        }
        return apexDir
    }
    
    private func getEpisodicFileURL(forBotId botId: UUID) -> URL {
        return getMemoryDirectory(forBotId: botId).appendingPathComponent("episodes.json")
    }
    
    public func recordEpisode(_ entry: EpisodicEntry) {
        let fileURL = getEpisodicFileURL(forBotId: entry.botId)
        var episodes = allEpisodes(forBotId: entry.botId)
        episodes.append(entry)
        
        // Keep most recent 1000
        if episodes.count > 1000 {
            let toArchive = Array(episodes.prefix(episodes.count - 1000))
            episodes = Array(episodes.suffix(1000))
            let archiveURL = getMemoryDirectory(forBotId: entry.botId).appendingPathComponent("episodes_archive.json")
            var archived = (try? loadJSON(from: archiveURL) as [EpisodicEntry]) ?? []
            archived.append(contentsOf: toArchive)
            try? saveJSON(archived, to: archiveURL)
        }
        
        try? saveJSON(episodes, to: fileURL)
    }
    
    public func recentEpisodes(forBotId botId: UUID, limit: Int) -> [EpisodicEntry] {
        let episodes = allEpisodes(forBotId: botId)
        return Array(episodes.sorted(by: { $0.timestamp > $1.timestamp }).prefix(limit))
    }
    
    public func allEpisodes(forBotId botId: UUID) -> [EpisodicEntry] {
        let fileURL = getEpisodicFileURL(forBotId: botId)
        return (try? loadJSON(from: fileURL) as [EpisodicEntry]) ?? []
    }
    
    // MARK: - Semantic Memory (subject-predicate-object graph facts)
    public struct SemanticFact: Identifiable, Codable, Sendable {
        public let id: UUID
        public let botId: UUID
        public let subject: String
        public let predicate: String
        public let object: String
        public let confidence: Double
        public let source: String
        public let createdAt: Date
        public var updatedAt: Date
        
        public init(id: UUID = UUID(), botId: UUID, subject: String, predicate: String, object: String, confidence: Double, source: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
            self.id = id
            self.botId = botId
            self.subject = subject
            self.predicate = predicate
            self.object = object
            self.confidence = confidence
            self.source = source
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
    
    private func getSemanticFileURL(forBotId botId: UUID) -> URL {
        return getMemoryDirectory(forBotId: botId).appendingPathComponent("semantic.json")
    }
    
    private func allFacts(forBotId botId: UUID) -> [SemanticFact] {
        let fileURL = getSemanticFileURL(forBotId: botId)
        return (try? loadJSON(from: fileURL) as [SemanticFact]) ?? []
    }
    
    public func assertFact(_ fact: SemanticFact) {
        let fileURL = getSemanticFileURL(forBotId: fact.botId)
        var facts = allFacts(forBotId: fact.botId)
        
        if let index = facts.firstIndex(where: { $0.subject == fact.subject && $0.predicate == fact.predicate && $0.object == fact.object }) {
            facts[index].updatedAt = Date()
        } else {
            facts.append(fact)
        }
        
        try? saveJSON(facts, to: fileURL)
    }
    
    public func retractFact(id: UUID) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let memoryDir = homeDir.appendingPathComponent(".apex/memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return }
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "semantic.json" {
                var facts: [SemanticFact] = (try? loadJSON(from: url)) ?? []
                if let index = facts.firstIndex(where: { $0.id == id }) {
                    facts.remove(at: index)
                    try? saveJSON(facts, to: url)
                    return 
                }
            }
        }
    }
    
    public func queryFacts(subject: String?, predicate: String?, object: String?) -> [SemanticFact] {
        var results: [SemanticFact] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let memoryDir = homeDir.appendingPathComponent(".apex/memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return [] }
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "semantic.json" {
                let facts: [SemanticFact] = (try? loadJSON(from: url)) ?? []
                for fact in facts {
                    let subjectMatches = subject == nil || fact.subject == subject
                    let predicateMatches = predicate == nil || fact.predicate == predicate
                    let objectMatches = object == nil || fact.object == object
                    
                    if subjectMatches && predicateMatches && objectMatches {
                        results.append(fact)
                    }
                }
            }
        }
        return results
    }
    
    public func searchFacts(keyword: String) -> [SemanticFact] {
        var results: [SemanticFact] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let memoryDir = homeDir.appendingPathComponent(".apex/memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return [] }
        let lowerKeyword = keyword.lowercased()
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "semantic.json" {
                let facts: [SemanticFact] = (try? loadJSON(from: url)) ?? []
                for fact in facts {
                    if fact.subject.lowercased().contains(lowerKeyword) ||
                        fact.predicate.lowercased().contains(lowerKeyword) ||
                        fact.object.lowercased().contains(lowerKeyword) {
                        results.append(fact)
                    }
                }
            }
        }
        return results
    }
    
    // MARK: - Procedural Memory (tool recipes and error recovery)
    public struct ProceduralRecipe: Identifiable, Codable, Sendable {
        public let id: UUID
        public let botId: UUID
        public let goalDescription: String
        public let toolSequence: [String]
        public let contextTags: [String]
        public var successCount: Int
        public var failureCount: Int
        public var lastUsedAt: Date
        public let notes: String
        
        public init(id: UUID = UUID(), botId: UUID, goalDescription: String, toolSequence: [String], contextTags: [String], successCount: Int = 0, failureCount: Int = 0, lastUsedAt: Date = Date(), notes: String = "") {
            self.id = id
            self.botId = botId
            self.goalDescription = goalDescription
            self.toolSequence = toolSequence
            self.contextTags = contextTags
            self.successCount = successCount
            self.failureCount = failureCount
            self.lastUsedAt = lastUsedAt
            self.notes = notes
        }
    }
    
    private func getProceduralFileURL(forBotId botId: UUID) -> URL {
        return getMemoryDirectory(forBotId: botId).appendingPathComponent("procedures.json")
    }
    
    private func allRecipes(forBotId botId: UUID) -> [ProceduralRecipe] {
        let fileURL = getProceduralFileURL(forBotId: botId)
        return (try? loadJSON(from: fileURL) as [ProceduralRecipe]) ?? []
    }
    
    public func recordRecipe(_ recipe: ProceduralRecipe) {
        let fileURL = getProceduralFileURL(forBotId: recipe.botId)
        var recipes = allRecipes(forBotId: recipe.botId)
        
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes[index] = recipe
        } else {
            recipes.append(recipe)
        }
        
        try? saveJSON(recipes, to: fileURL)
    }
    
    public func lookupRecipes(forGoal goal: String) -> [ProceduralRecipe] {
        var results: [ProceduralRecipe] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let memoryDir = homeDir.appendingPathComponent(".apex/memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return [] }
        let lowerGoal = goal.lowercased()
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "procedures.json" {
                let recipes: [ProceduralRecipe] = (try? loadJSON(from: url)) ?? []
                for recipe in recipes {
                    if recipe.goalDescription.lowercased().contains(lowerGoal) ||
                        recipe.notes.lowercased().contains(lowerGoal) {
                        results.append(recipe)
                    }
                }
            }
        }
        
        return results.sorted { ($0.successCount - $0.failureCount) > ($1.successCount - $1.failureCount) }
    }
    
    public func updateRecipeStats(id: UUID, succeeded: Bool) {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let memoryDir = homeDir.appendingPathComponent(".apex/memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return }
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "procedures.json" {
                var recipes: [ProceduralRecipe] = (try? loadJSON(from: url)) ?? []
                if let index = recipes.firstIndex(where: { $0.id == id }) {
                    if succeeded {
                        recipes[index].successCount += 1
                    } else {
                        recipes[index].failureCount += 1
                    }
                    recipes[index].lastUsedAt = Date()
                    try? saveJSON(recipes, to: url)
                    return
                }
            }
        }
    }
    
    // MARK: - Consolidated Context Builder
    public func buildContextSummary(forBotId botId: UUID, maxLength: Int) -> String {
        let episodes = recentEpisodes(forBotId: botId, limit: 5)
        let facts = allFacts(forBotId: botId).prefix(10)
        let recipes = allRecipes(forBotId: botId).sorted(by: { ($0.successCount - $0.failureCount) > ($1.successCount - $1.failureCount) }).prefix(3)
        
        var summary = ""
        summary += "Recent Episodes:\n"
        for ep in episodes {
            summary += "- \(ep.summary)\n"
        }
        summary += "\nFacts:\n"
        for fact in facts {
            summary += "\(fact.subject) \(fact.predicate) \(fact.object)\n"
        }
        summary += "\nProcedures:\n"
        for recipe in recipes {
            summary += "\(recipe.goalDescription): \(recipe.toolSequence.joined(separator: " -> "))\n"
        }
        
        if summary.count > maxLength {
            let index = summary.index(summary.startIndex, offsetBy: maxLength)
            return String(summary[..<index])
        }
        
        return summary
    }
    
    // MARK: - Dream Cycle (consolidation)
    public func runConsolidationCycle(forBotId botId: UUID) async {
        let fileURL = getEpisodicFileURL(forBotId: botId)
        var episodes = allEpisodes(forBotId: botId)
        
        var summaryCounts: [String: Int] = [:]
        for ep in episodes {
            summaryCounts[ep.summary, default: 0] += 1
        }
        
        for (summary, count) in summaryCounts where count > 2 {
            let fact = SemanticFact(
                botId: botId,
                subject: botId.uuidString,
                predicate: "frequently_does",
                object: summary,
                confidence: 1.0,
                source: "inferred"
            )
            assertFact(fact)
        }
        
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        episodes.removeAll { $0.timestamp < thirtyDaysAgo }
        try? saveJSON(episodes, to: fileURL)
    }
    
    // MARK: - Helper
    private func loadJSON<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(T.self, from: data)
    }
    
    private func saveJSON<T: Encodable>(_ object: T, to url: URL) throws {
        let data = try JSONEncoder().encode(object)
        try data.write(to: url, options: .atomic)
    }
}
