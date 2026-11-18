import Foundation
import NaturalLanguage
import SharedKit
import SwiftData

// MARK: - Memory Chunk

/// A discrete, cited chunk of memory or knowledge with exact file and line bounds.
public struct MemoryChunk: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let filePath: String
    public let relativePath: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let tier: String
    public let tokens: [String]
    public let embedding: [Double]?

    public init(
        id: UUID = UUID(),
        filePath: String,
        relativePath: String,
        startLine: Int,
        endLine: Int,
        content: String,
        tier: String,
        tokens: [String],
        embedding: [Double]? = nil
    ) {
        self.id = id
        self.filePath = filePath
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.tier = tier
        self.tokens = tokens
        self.embedding = embedding
    }

    /// Formatted citation string, e.g. `[MEMORY.md:12-18]` or `[daily/2026-11-18.md:5]`.
    public var citation: String {
        if startLine == endLine {
            return "[\(relativePath):\(startLine)]"
        } else {
            return "[\(relativePath):\(startLine)-\(endLine)]"
        }
    }
}

// MARK: - Search Result

/// A ranked hybrid search result with file/line citation and score breakdown.
public struct MemorySearchResult: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let filePath: String
    public let relativePath: String
    public let startLine: Int
    public let endLine: Int
    public let citation: String
    public let content: String
    public let tier: String
    public let score: Double
    public let vectorScore: Double
    public let keywordScore: Double
    public let matchSnippet: String

    public init(
        id: UUID = UUID(),
        filePath: String,
        relativePath: String,
        startLine: Int,
        endLine: Int,
        citation: String,
        content: String,
        tier: String,
        score: Double,
        vectorScore: Double,
        keywordScore: Double,
        matchSnippet: String
    ) {
        self.id = id
        self.filePath = filePath
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.citation = citation
        self.content = content
        self.tier = tier
        self.score = score
        self.vectorScore = vectorScore
        self.keywordScore = keywordScore
        self.matchSnippet = matchSnippet
    }

    /// Human-readable formatted string for tool output and terminal display.
    public var formattedDescription: String {
        let vPct = Int((vectorScore * 100).rounded())
        let kPct = Int((keywordScore * 100).rounded())
        let sPct = Int((score * 100).rounded())
        return """
        Source: \(citation) (Score: \(sPct)%, Vector: \(vPct)%, Keyword: \(kPct)%)
        Tier: \(tier) | File: \(filePath) (Lines \(startLine)-\(endLine))
        Content:
        \(content)
        """
    }
}

// MARK: - Exact Span

/// Exact range retrieval result from a file on disk.
public struct MemorySpan: Sendable, Codable, Equatable {
    public let filePath: String
    public let relativePath: String
    public let startLine: Int
    public let endLine: Int
    public let content: String
    public let totalLinesInFile: Int
    public let citation: String

    public init(
        filePath: String,
        relativePath: String,
        startLine: Int,
        endLine: Int,
        content: String,
        totalLinesInFile: Int,
        citation: String
    ) {
        self.filePath = filePath
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.totalLinesInFile = totalLinesInFile
        self.citation = citation
    }

    public var formattedDescription: String {
        return """
        Source: \(citation)
        File: \(filePath) (Lines \(startLine)-\(endLine) of \(totalLinesInFile))
        Content:
        \(content)
        """
    }
}

// MARK: - Hybrid Memory Retriever

/// High-performance local hybrid (vector + keyword) retriever for files-first memory tiers.
@MainActor
public final class HybridMemoryRetriever {
    public static let shared = HybridMemoryRetriever()

    private init() {}

    // Cache structure: filePath -> (modifiedDate, chunks)
    private var chunkCache: [String: (Date, [MemoryChunk])] = [:]

    // MARK: - Public Search API

    /// Executes a hybrid vector + keyword search over all files-first memory tiers for a space.
    public func search(
        query: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil,
        limit: Int = 10,
        tierFilter: String? = nil
    ) -> [MemorySearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let chunks = indexAllTiers(space: space, workspacePath: workspacePath)
        let filteredChunks: [MemoryChunk]
        if let filter = tierFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !filter.isEmpty {
            filteredChunks = chunks.filter { $0.tier.lowercased() == filter }
        } else {
            filteredChunks = chunks
        }

        let queryTokens = Self.tokenize(q)
        let queryVector = EmbeddingHelper.getVector(for: q)

        var scoredResults: [MemorySearchResult] = []

        for chunk in filteredChunks {
            let kwScore = Self.computeKeywordScore(
                chunkTokens: chunk.tokens,
                chunkContent: chunk.content,
                query: q,
                queryTokens: queryTokens
            )

            let vecScore = Self.computeVectorScore(
                queryEmbedding: queryVector,
                chunkEmbedding: chunk.embedding
            )

            let fusedScore = Self.fuseScores(vectorScore: vecScore, keywordScore: kwScore)

            // Include chunks that meet a minimum combined threshold
            if fusedScore >= 0.05 {
                let snippet = Self.extractSnippet(from: chunk.content, query: q, tokens: queryTokens)
                let result = MemorySearchResult(
                    id: chunk.id,
                    filePath: chunk.filePath,
                    relativePath: chunk.relativePath,
                    startLine: chunk.startLine,
                    endLine: chunk.endLine,
                    citation: chunk.citation,
                    content: chunk.content,
                    tier: chunk.tier,
                    score: fusedScore,
                    vectorScore: vecScore,
                    keywordScore: kwScore,
                    matchSnippet: snippet
                )
                scoredResults.append(result)
            }
        }

        // Sort descending by score, tiebreak by line count and startLine
        scoredResults.sort {
            if abs($0.score - $1.score) > 0.001 {
                return $0.score > $1.score
            }
            return $0.startLine < $1.startLine
        }

        return Array(scoredResults.prefix(limit))
    }

    // MARK: - Exact Span Retrieval (memory_get)

    /// Retrieves an exact line range from a file, returning the exact source span.
    public func getExactSpan(
        filePath: String,
        startLine: Int,
        endLine: Int,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws -> MemorySpan {
        let wsRoot = SpaceMemoryTierManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let resolvedPath = Self.resolveFilePath(filePath, workspaceRoot: wsRoot)

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw NSError(
                domain: "ApexAgent.HybridMemoryRetriever",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "File not found at path: '\(resolvedPath)'"]
            )
        }

        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        let extracted = Self.extractExactSpan(from: content, startLine: startLine, endLine: endLine)
        let relPath = Self.computeRelativePath(fullPath: resolvedPath, workspaceRoot: wsRoot)
        let citation = extracted.effectiveStart == extracted.effectiveEnd
            ? "[\(relPath):\(extracted.effectiveStart)]"
            : "[\(relPath):\(extracted.effectiveStart)-\(extracted.effectiveEnd)]"

        return MemorySpan(
            filePath: resolvedPath,
            relativePath: relPath,
            startLine: extracted.effectiveStart,
            endLine: extracted.effectiveEnd,
            content: extracted.span,
            totalLinesInFile: extracted.totalLines,
            citation: citation
        )
    }

    // MARK: - Tier Indexing

    /// Scans and indexes all active memory tiers for a space.
    public func indexAllTiers(
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) -> [MemoryChunk] {
        let wsRoot = SpaceMemoryTierManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
        var allChunks: [MemoryChunk] = []

        // Tier 1: Curated MEMORY.md
        let curatedPath = SpaceMemoryTierManager.shared.curatedMemoryPath(space: space, workspacePath: workspacePath)
        if FileManager.default.fileExists(atPath: curatedPath) {
            allChunks.append(contentsOf: indexFile(at: curatedPath, workspaceRoot: wsRoot, tier: "curated"))
        }

        // Tier 2: Persona (PERSONA.md)
        let personaPath = SpaceMemoryTierManager.shared.personaPath(space: space, workspacePath: workspacePath)
        if FileManager.default.fileExists(atPath: personaPath) {
            allChunks.append(contentsOf: indexFile(at: personaPath, workspaceRoot: wsRoot, tier: "persona"))
        }

        // Tier 3: User Context (USER.md)
        let userPath = SpaceMemoryTierManager.shared.userContextPath(space: space, workspacePath: workspacePath)
        if FileManager.default.fileExists(atPath: userPath) {
            allChunks.append(contentsOf: indexFile(at: userPath, workspaceRoot: wsRoot, tier: "user"))
        }

        // Tier 4: Daily Notes
        let dailyDir = SpaceMemoryTierManager.shared.dailyNotesDirectory(space: space, workspacePath: workspacePath)
        if let items = try? FileManager.default.contentsOfDirectory(at: dailyDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for item in items where item.pathExtension.lowercased() == "md" {
                allChunks.append(contentsOf: indexFile(at: item.path, workspaceRoot: wsRoot, tier: "daily"))
            }
        }

        return allChunks
    }

    /// Indexes a single markdown file into chunks, using the in-memory cache if file has not changed.
    public func indexFile(
        at path: String,
        workspaceRoot: String,
        tier: String
    ) -> [MemoryChunk] {
        let fileURL = URL(fileURLWithPath: path)
        let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

        if let cached = chunkCache[path], cached.0 >= modDate {
            return cached.1
        }

        guard let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty else {
            chunkCache[path] = (modDate, [])
            return []
        }

        let relPath = Self.computeRelativePath(fullPath: path, workspaceRoot: workspaceRoot)
        let chunks = Self.chunk(text: content, filePath: path, relativePath: relPath, tier: tier)
        chunkCache[path] = (modDate, chunks)
        return chunks
    }

    /// Clears the in-memory chunk cache.
    public func clearCache() {
        chunkCache.removeAll()
    }

    // MARK: - Pure Helper Functions (Non-Isolated)

    /// Tokenizes input text into normalized lowercased alphanumeric words of 2+ characters.
    public static func tokenize(_ text: String) -> [String] {
        let lower = text.lowercased()
        return lower
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    /// Chunks a markdown file into discrete sections while preserving exact 1-based start and end line numbers.
    public static func chunk(
        text: String,
        filePath: String,
        relativePath: String,
        tier: String
    ) -> [MemoryChunk] {
        let lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var chunks: [MemoryChunk] = []
        var currentLines: [String] = []
        var currentStartLine: Int = 1

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = trimmed.hasPrefix("#")
            let isEmpty = trimmed.isEmpty

            // Section boundary: new markdown heading, or blank line after accumulating a paragraph
            if (isHeading || (isEmpty && currentLines.count >= 2)) && !currentLines.isEmpty {
                let endLine = currentStartLine + currentLines.count - 1
                let rawBlock = currentLines.joined(separator: "\n")
                let content = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let tokens = tokenize(content)
                    let embedding = EmbeddingHelper.getVector(for: content)
                    chunks.append(MemoryChunk(
                        id: UUID(),
                        filePath: filePath,
                        relativePath: relativePath,
                        startLine: currentStartLine,
                        endLine: endLine,
                        content: rawBlock,
                        tier: tier,
                        tokens: tokens,
                        embedding: embedding
                    ))
                }
                currentLines.removeAll()
                currentStartLine = lineNumber
            }

            if isEmpty && currentLines.isEmpty {
                currentStartLine = lineNumber + 1
                continue
            }

            currentLines.append(line)

            // Hard boundary: break very long blocks at 30 lines
            if currentLines.count >= 30 {
                let endLine = currentStartLine + currentLines.count - 1
                let rawBlock = currentLines.joined(separator: "\n")
                let content = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    let tokens = tokenize(content)
                    let embedding = EmbeddingHelper.getVector(for: content)
                    chunks.append(MemoryChunk(
                        id: UUID(),
                        filePath: filePath,
                        relativePath: relativePath,
                        startLine: currentStartLine,
                        endLine: endLine,
                        content: rawBlock,
                        tier: tier,
                        tokens: tokens,
                        embedding: embedding
                    ))
                }
                currentLines.removeAll()
                currentStartLine = lineNumber + 1
            }
        }

        if !currentLines.isEmpty {
            let endLine = currentStartLine + currentLines.count - 1
            let rawBlock = currentLines.joined(separator: "\n")
            let content = rawBlock.trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                let tokens = tokenize(content)
                let embedding = EmbeddingHelper.getVector(for: content)
                chunks.append(MemoryChunk(
                    id: UUID(),
                    filePath: filePath,
                    relativePath: relativePath,
                    startLine: currentStartLine,
                    endLine: endLine,
                    content: rawBlock,
                    tier: tier,
                    tokens: tokens,
                    embedding: embedding
                ))
            }
        }

        return chunks
    }

    /// Extracts an exact line-bounded span from text. Clamps safely to 1-based bounds.
    public static func extractExactSpan(
        from text: String,
        startLine: Int,
        endLine: Int
    ) -> (span: String, effectiveStart: Int, effectiveEnd: Int, totalLines: Int) {
        let lines = text.components(separatedBy: "\n")
        let totalLines = max(1, lines.count)
        let effStart = max(1, min(startLine, totalLines))
        let effEnd = max(effStart, min(endLine, totalLines))
        let slice = lines[(effStart - 1)...(effEnd - 1)]
        return (
            span: slice.joined(separator: "\n"),
            effectiveStart: effStart,
            effectiveEnd: effEnd,
            totalLines: totalLines
        )
    }

    /// Computes BM25-style keyword score in range [0.0, 1.0].
    public static func computeKeywordScore(
        chunkTokens: [String],
        chunkContent: String,
        query: String,
        queryTokens: [String]
    ) -> Double {
        guard !queryTokens.isEmpty else { return 0.0 }
        let qLower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cLower = chunkContent.lowercased()

        var score = 0.0

        // Exact phrase match bonus
        if cLower.contains(qLower) {
            score += 0.5
        }

        // Token overlap ratio
        let chunkSet = Set(chunkTokens)
        let matched = queryTokens.filter { chunkSet.contains($0) }.count
        let overlapRatio = Double(matched) / Double(queryTokens.count)
        score += overlapRatio * 0.4

        // Heading bonus
        if cLower.hasPrefix("#") && matched > 0 {
            score += 0.1
        }

        return min(1.0, score)
    }

    /// Computes cosine similarity vector score in range [0.0, 1.0].
    public static func computeVectorScore(
        queryEmbedding: [Double]?,
        chunkEmbedding: [Double]?
    ) -> Double {
        guard let q = queryEmbedding, let c = chunkEmbedding, !q.isEmpty, !c.isEmpty else {
            return 0.0
        }
        let sim = EmbeddingHelper.cosineSimilarity(v1: q, v2: c)
        return max(0.0, min(1.0, sim))
    }

    /// Fuses vector and keyword scores into one combined ranking score in range [0.0, 1.0].
    public static func fuseScores(vectorScore: Double, keywordScore: Double) -> Double {
        var fused: Double = 0.0
        if vectorScore > 0.05 && keywordScore > 0.05 {
            // Synergistic bonus when both vector and keyword signals corroborate
            fused = 0.5 * vectorScore + 0.5 * keywordScore + 0.10
        } else if vectorScore > 0.05 {
            // Semantic match alone
            fused = 0.8 * vectorScore
        } else if keywordScore > 0.05 {
            // Keyword match alone
            fused = 0.8 * keywordScore
        }
        return max(0.0, min(1.0, fused))
    }

    public static func extractSnippet(from content: String, query: String, tokens: [String]) -> String {
        let lines = content.components(separatedBy: "\n")
        let qLower = query.lowercased()
        for (idx, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower.contains(qLower) || tokens.contains(where: { lower.contains($0) }) {
                let start = max(0, idx - 1)
                let end = min(lines.count - 1, idx + 2)
                return lines[start...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(content.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func computeRelativePath(fullPath: String, workspaceRoot: String) -> String {
        let root = (workspaceRoot as NSString).standardizingPath
        let full = (fullPath as NSString).standardizingPath
        if full.hasPrefix(root) {
            let rel = String(full.dropFirst(root.count))
            return rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return (full as NSString).lastPathComponent
    }

    public static func resolveFilePath(_ rawPath: String, workspaceRoot: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        return URL(fileURLWithPath: workspaceRoot).appendingPathComponent(expanded).path
    }
}
