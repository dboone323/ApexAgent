import Foundation
import Observation
import SharedKit

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
        let apexDir = ApexAgentStoragePaths.directory("memory")
            .appendingPathComponent(botId.uuidString, isDirectory: true)
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
        let memoryDir = ApexAgentStoragePaths.directory("memory")
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
    
    public func queryFacts(subject: String?, predicate: String?, object: String?, botId: UUID? = nil) -> [SemanticFact] {
        if let botId {
            let facts = allFacts(forBotId: botId)
            return facts.filter { fact in
                let subjectMatches = subject == nil || fact.subject == subject
                let predicateMatches = predicate == nil || fact.predicate == predicate
                let objectMatches = object == nil || fact.object == object
                return subjectMatches && predicateMatches && objectMatches
            }
        }
        var results: [SemanticFact] = []
        let memoryDir = ApexAgentStoragePaths.directory("memory")
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
    
    public func searchFacts(keyword: String, botId: UUID? = nil) -> [SemanticFact] {
        let lowerKeyword = keyword.lowercased()
        if let botId {
            let facts = allFacts(forBotId: botId)
            if lowerKeyword.isEmpty { return facts }
            return facts.filter { fact in
                fact.subject.lowercased().contains(lowerKeyword) ||
                fact.predicate.lowercased().contains(lowerKeyword) ||
                fact.object.lowercased().contains(lowerKeyword)
            }
        }
        var results: [SemanticFact] = []
        let memoryDir = ApexAgentStoragePaths.directory("memory")
        guard let enumerator = FileManager.default.enumerator(at: memoryDir, includingPropertiesForKeys: nil) else { return [] }
        
        for case let url as URL in enumerator {
            if url.lastPathComponent == "semantic.json" {
                let facts: [SemanticFact] = (try? loadJSON(from: url)) ?? []
                for fact in facts {
                    if lowerKeyword.isEmpty ||
                        fact.subject.lowercased().contains(lowerKeyword) ||
                        fact.predicate.lowercased().contains(lowerKeyword) ||
                        fact.object.lowercased().contains(lowerKeyword) {
                        results.append(fact)
                    }
                }
            }
        }
        return results
    }

    public func storeBotFact(
        botId: UUID,
        subject: String,
        predicate: String,
        object: String,
        confidence: Double = 1.0,
        source: String = "bot_experience"
    ) {
        let fact = SemanticFact(
            botId: botId,
            subject: subject,
            predicate: predicate,
            object: object,
            confidence: confidence,
            source: source
        )
        assertFact(fact)
    }

    public func botMemories(for botId: UUID, limit: Int = 10) -> (episodes: [EpisodicEntry], facts: [SemanticFact]) {
        let eps = recentEpisodes(forBotId: botId, limit: limit)
        let facts = Array(allFacts(forBotId: botId).prefix(limit))
        return (eps, facts)
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
        let memoryDir = ApexAgentStoragePaths.directory("memory")
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
        let memoryDir = ApexAgentStoragePaths.directory("memory")
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
    
    // MARK: - Context Compaction (Automatic History Compression)
    
    /// Compacts an array of chat messages by summarizing older turns and archiving them into durable Episodic Memory.
    /// Preserves the most recent `keepRecent` messages untouched, and replaces older messages with a single structured summary.
    func compactMessages(
        messages: [ChatMessage],
        keepRecent: Int = 4,
        maxChars: Int = 4000,
        botId: UUID,
        summarizer: (String) async throws -> String
    ) async throws -> (compacted: [ChatMessage], archivedCount: Int) {
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        let effectiveKeepRecent: Int
        if messages.count <= keepRecent + 1 && totalChars > 20000 && messages.count > 1 {
            effectiveKeepRecent = 1
        } else {
            effectiveKeepRecent = keepRecent
        }
        
        guard messages.count > effectiveKeepRecent + 1 || (totalChars > 20000 && messages.count > 1) else {
            return (messages, 0)
        }
        
        let splitIndex = max(1, messages.count - effectiveKeepRecent)
        let olderMessages = Array(messages[..<splitIndex])
        let recentMessages = Array(messages[splitIndex...])
        
        // Build transcript of older turns for summarization
        var transcript = "Summarize the key facts, decisions, file paths, tool actions, and context from this earlier segment:\n\n"
        for msg in olderMessages {
            let roleStr = switch msg.role {
            case .user: "User"
            case .assistant: "Assistant"
            case .system: "System"
            }
            transcript += "[\(roleStr)]: \(msg.content)\n"
        }
        
        if transcript.count > maxChars {
            transcript = String(transcript.prefix(maxChars)) + "\n[... truncated for compaction window ...]"
        }
        
        let summaryText = try await summarizer(transcript)
        let cleanSummary = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !cleanSummary.isEmpty else {
            return (messages, 0)
        }
        
        // 1. Archive compacted segment into durable episodic memory
        let episode = EpisodicEntry(
            botId: botId,
            eventType: "context_compaction",
            summary: cleanSummary,
            metadata: ["compactedTurnCount": "\(olderMessages.count)"]
        )
        recordEpisode(episode)
        
        // 2. Formulate structured summary message
        let summaryMessage = ChatMessage(
            role: .system,
            content: "### 📜 Compacted Session Context (Previous Turns Summarized):\n\(cleanSummary)"
        )
        
        var compactedResult: [ChatMessage] = [summaryMessage]
        compactedResult.append(contentsOf: recentMessages)
        
        return (compactedResult, olderMessages.count)
    }
    
    // MARK: - Semantic Embeddings & Vector Memory Retrieval (Ollama nomic-embed-text:latest)
    
    /// Queries Ollama's `/api/embed` endpoint (`http://localhost:11434/api/embed` by default)
    /// using `"nomic-embed-text:latest"` to produce a real semantic vector embedding.
    /// Automatically falls back to `deterministicHashEmbedding(for:)` if Ollama is offline or unreachable.
    public func generateEmbedding(
        for text: String,
        model: String = "nomic-embed-text:latest",
        hostURL: String? = nil
    ) async -> [Double] {
        let resolvedHost = hostURL ?? UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
        guard let baseURL = URL(string: resolvedHost) else {
            return Self.deterministicHashEmbedding(for: text)
        }
        let endpoint = baseURL.appendingPathComponent("api/embed")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3.0
        
        let payload: [String: Any] = [
            "model": model,
            "input": text
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return Self.deterministicHashEmbedding(for: text)
        }
        request.httpBody = body
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Self.deterministicHashEmbedding(for: text)
            }
            if let embeddings = json["embeddings"] as? [[Double]], let first = embeddings.first, !first.isEmpty {
                return first
            }
            if let embeddingsNum = json["embeddings"] as? [[NSNumber]], let first = embeddingsNum.first, !first.isEmpty {
                return first.map { $0.doubleValue }
            }
            if let single = json["embedding"] as? [Double], !single.isEmpty {
                return single
            }
            if let singleNum = json["embedding"] as? [NSNumber], !singleNum.isEmpty {
                return singleNum.map { $0.doubleValue }
            }
        } catch {
            // Fall through to deterministic local hash embedding when Ollama is offline
        }
        return Self.deterministicHashEmbedding(for: text)
    }
    
    /// Deterministic local hash embedding (token + character 3-gram feature hashing with L2 normalization)
    /// used when Ollama `/api/embed` is offline.
    public nonisolated static func deterministicHashEmbedding(for text: String, dimensions: Int = 64) -> [Double] {
        let dim = max(dimensions, 8)
        var vector = [Double](repeating: 0.0, count: dim)
        let normalized = text.lowercased()
        let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        
        func fnv1a(_ str: String) -> UInt64 {
            var hash: UInt64 = 14695981039346656037
            for byte in str.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 1099511628211
            }
            return hash
        }
        
        for token in tokens {
            let h = fnv1a(token)
            let idx = Int(h % UInt64(dim))
            let sign: Double = ((h >> 32) & 1) == 0 ? 1.0 : -1.0
            vector[idx] += sign * 1.5
            
            // Character 3-grams for subword similarity
            let chars = Array(token)
            if chars.count >= 3 {
                for i in 0...(chars.count - 3) {
                    let trigram = String(chars[i..<(i + 3)])
                    let th = fnv1a(trigram)
                    let tidx = Int(th % UInt64(dim))
                    let tsign: Double = ((th >> 32) & 1) == 0 ? 1.0 : -1.0
                    vector[tidx] += tsign * 0.5
                }
            }
        }
        
        let norm = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<dim {
                vector[i] /= norm
            }
        } else {
            vector[0] = 1.0
        }
        return vector
    }
    
    /// Encodes a `[Double]` embedding vector into `Data` for `AgentMemoryEntry.embedding`.
    public nonisolated static func encodeEmbedding(_ vector: [Double]) -> Data {
        (try? JSONEncoder().encode(vector)) ?? Data()
    }
    
    /// Decodes a `[Double]` embedding vector from `AgentMemoryEntry.embedding`.
    public nonisolated static func decodeEmbedding(_ data: Data) -> [Double]? {
        guard !data.isEmpty else { return nil }
        if let decoded = try? JSONDecoder().decode([Double].self, from: data), !decoded.isEmpty {
            return decoded
        }
        return nil
    }
    
    /// Computes cosine similarity between two embedding vectors in `[-1.0, 1.0]`.
    public nonisolated static func cosineSimilarity(_ v1: [Double], _ v2: [Double]) -> Double {
        guard v1.count == v2.count, !v1.isEmpty else { return 0.0 }
        var dot = 0.0
        var mag1 = 0.0
        var mag2 = 0.0
        for i in 0..<v1.count {
            dot += v1[i] * v2[i]
            mag1 += v1[i] * v1[i]
            mag2 += v2[i] * v2[i]
        }
        let denom = sqrt(mag1) * sqrt(mag2)
        guard denom > 0 else { return 0.0 }
        return dot / denom
    }
    
    /// Creates an `AgentMemoryEntry` populated with a semantic embedding vector from Ollama
    /// `nomic-embed-text:latest` (or deterministic fallback if offline).
    public func createMemoryEntry(
        content: String,
        source: MemorySource = .userChat,
        tags: [String] = [],
        model: String = "nomic-embed-text:latest",
        hostURL: String? = nil
    ) async -> AgentMemoryEntry {
        let vector = await generateEmbedding(for: content, model: model, hostURL: hostURL)
        let data = Self.encodeEmbedding(vector)
        return AgentMemoryEntry(
            content: content,
            embedding: data,
            source: source,
            relevanceScore: 1.0,
            tags: tags
        )
    }
    
    /// Ranks and retrieves `AgentMemoryEntry` items using cosine similarity against `entry.embedding`.
    public func retrieveRelevantMemories(
        query: String,
        from entries: [AgentMemoryEntry],
        topK: Int = 5,
        minimumSimilarity: Double = -1.0,
        model: String = "nomic-embed-text:latest",
        hostURL: String? = nil
    ) async -> [(entry: AgentMemoryEntry, similarity: Double)] {
        guard !entries.isEmpty, topK > 0 else { return [] }
        let queryVector = await generateEmbedding(for: query, model: model, hostURL: hostURL)
        var scored: [(entry: AgentMemoryEntry, similarity: Double)] = []
        let now = Date()
        
        for entry in entries {
            let entryVector: [Double]
            if let decoded = Self.decodeEmbedding(entry.embedding), decoded.count == queryVector.count {
                entryVector = decoded
            } else {
                entryVector = Self.deterministicHashEmbedding(for: entry.content, dimensions: queryVector.count)
            }
            let sim: Double
            if entryVector.count == queryVector.count {
                sim = Self.cosineSimilarity(queryVector, entryVector)
            } else {
                let fallbackQuery = Self.deterministicHashEmbedding(for: query, dimensions: entryVector.count)
                sim = Self.cosineSimilarity(fallbackQuery, entryVector)
            }
            entry.relevanceScore = sim
            entry.lastAccessedAt = now
            if sim >= minimumSimilarity {
                scored.append((entry: entry, similarity: sim))
            }
        }
        
        scored.sort { $0.similarity > $1.similarity }
        return Array(scored.prefix(topK))
    }

    /// High-level query matching semantic facts, procedural tool recipes, and episodic memories.
    public func retrieveRelevantContext(query: String, botId: UUID? = nil) -> String {
        var sections: [String] = []
        let facts = searchFacts(keyword: query, botId: botId)
        if !facts.isEmpty {
            let factsList = facts.prefix(5).map { "- \($0.subject) \($0.predicate) \($0.object)" }.joined(separator: "\n")
            sections.append("### Relevant Semantic Knowledge\n\(factsList)")
        }
        let recipes = lookupRecipes(forGoal: query)
        if !recipes.isEmpty {
            let recipesList = recipes.prefix(3).map { "- Goal: \($0.goalDescription) (Tools: \($0.toolSequence.joined(separator: " -> ")))" }.joined(separator: "\n")
            sections.append("### Procedural Recipes\n\(recipesList)")
        }
        if let botId = botId {
            let summary = buildContextSummary(forBotId: botId, maxLength: 500)
            if !summary.isEmpty {
                sections.append("### Bot Context Summary\n\(summary)")
            }
        }
        return sections.isEmpty ? "No indexed cognitive memory found matching '\(query)'." : sections.joined(separator: "\n\n")
    }
    
    // MARK: - Helper
    private func loadJSON<T: Decodable>(from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            ResilientJSONStore.shared.quarantineCorruptFile(
                at: url,
                subsystem: "CognitiveMemoryEngine",
                errorDescription: String(describing: error)
            )
            throw error
        }
    }
    
    private func saveJSON<T: Encodable>(_ object: T, to url: URL) throws {
        try ResilientJSONStore.shared.save(object, to: url)
    }

    // MARK: - Markdown Summaries & Memory Management

    public func clearMemory(forBotId botId: UUID) {
        clearWorkingContext(forBotId: botId)
        let dir = getMemoryDirectory(forBotId: botId)
        try? FileManager.default.removeItem(at: dir)
    }

    public func exportEpisodicSummaryMarkdown(forBotId botId: UUID, limit: Int = 20) -> String {
        let episodes = recentEpisodes(forBotId: botId, limit: limit)
        guard !episodes.isEmpty else {
            return "No episodic memory entries recorded for bot `\(botId.uuidString.prefix(8))`."
        }

        var md = "### 🧠 Episodic Memory Log (Bot `\(botId.uuidString.prefix(8))`)\n\n"
        md += "| Event Type | Timestamp | Summary |\n"
        md += "|---|---|---|\n"

        for ep in episodes {
            let safeType = ep.eventType.replacingOccurrences(of: "|", with: "\\|")
            let safeSummary = ep.summary.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            md += "| `\(safeType)` | `\(ep.timestamp)` | \(safeSummary) |\n"
        }
        return md
    }

    public func exportSemanticGraphMarkdown(forBotId botId: UUID) -> String {
        let facts = allFacts(forBotId: botId)
        guard !facts.isEmpty else {
            return "No semantic knowledge facts established for bot `\(botId.uuidString.prefix(8))`."
        }

        var md = "### 🕸️ Semantic Knowledge Graph (Bot `\(botId.uuidString.prefix(8))`)\n\n"
        md += "| Subject | Predicate | Object | Confidence | Source |\n"
        md += "|---|---|---|---|---|\n"

        for fact in facts {
            let s = fact.subject.replacingOccurrences(of: "|", with: "\\|")
            let p = fact.predicate.replacingOccurrences(of: "|", with: "\\|")
            let o = fact.object.replacingOccurrences(of: "|", with: "\\|")
            let confStr = String(format: "%.2f", fact.confidence)
            md += "| **\(s)** | `\(p)` | \(o) | `\(confStr)` | \(fact.source) |\n"
        }
        return md
    }

}

extension CognitiveMemoryEngine.EpisodicEntry {
    public func formatAsMarkdown() -> String {
        var md = "### 🧠 Episode: \(eventType) — \(timestamp)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Type | `\(eventType)` |\n"
        md += "| Summary | \(String(summary.prefix(250)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        if !metadata.isEmpty {
            md += "| Metadata | `\(metadata.count)` keys |\n"
        }
        return md
    }

    public var isWellFormed: Bool {
        !eventType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
