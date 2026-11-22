import Foundation
import SharedKit
import SwiftData

// MARK: - Memory Topic Item

/// Represents a discrete inspectable memory fact or block tied to a specific Space and source file.
public struct MemoryTopicItem: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var key: String
    public var statement: String
    public var sourceCitation: String
    public var filePath: String
    public var relativePath: String
    public var startLine: Int
    public var endLine: Int
    public var tier: String
    public var dateString: String
    public var isPaused: Bool
    public var rawSourceSnippet: String
    public var provenanceRationale: String

    public init(
        id: UUID = UUID(),
        key: String,
        statement: String,
        sourceCitation: String,
        filePath: String,
        relativePath: String,
        startLine: Int,
        endLine: Int,
        tier: String,
        dateString: String = "",
        isPaused: Bool = false,
        rawSourceSnippet: String = "",
        provenanceRationale: String = ""
    ) {
        self.id = id
        self.key = key
        self.statement = statement
        self.sourceCitation = sourceCitation
        self.filePath = filePath
        self.relativePath = relativePath
        self.startLine = startLine
        self.endLine = endLine
        self.tier = tier
        self.dateString = dateString
        self.isPaused = isPaused
        self.rawSourceSnippet = rawSourceSnippet.isEmpty ? statement : rawSourceSnippet
        self.provenanceRationale = provenanceRationale
    }
}

// MARK: - Memory Topic Group

/// A high-level topic grouping multiple memory facts or blocks.
public struct MemoryTopicGroup: Identifiable, Sendable, Codable, Equatable {
    public var id: String { topic }
    public let topic: String
    public var items: [MemoryTopicItem]
    public var isPaused: Bool

    public init(topic: String, items: [MemoryTopicItem], isPaused: Bool = false) {
        self.topic = topic
        self.items = items
        self.isPaused = isPaused
    }
}

// MARK: - Memory Provenance ("Why do you think that?")

/// Answers the question "Why do you think that?" by attributing a belief to its source origin, lines, and rationale.
public struct MemoryProvenance: Sendable, Codable, Equatable {
    public let key: String
    public let statement: String
    public let sourceCitation: String
    public let filePath: String
    public let relativePath: String
    public let lineRange: String
    public let tier: String
    public let dateRecorded: String
    public let verbatimSourceSnippet: String
    public let provenanceAnswer: String

    public init(
        key: String,
        statement: String,
        sourceCitation: String,
        filePath: String,
        relativePath: String,
        lineRange: String,
        tier: String,
        dateRecorded: String,
        verbatimSourceSnippet: String,
        provenanceAnswer: String
    ) {
        self.key = key
        self.statement = statement
        self.sourceCitation = sourceCitation
        self.filePath = filePath
        self.relativePath = relativePath
        self.lineRange = lineRange
        self.tier = tier
        self.dateRecorded = dateRecorded
        self.verbatimSourceSnippet = verbatimSourceSnippet
        self.provenanceAnswer = provenanceAnswer
    }
}

// MARK: - Memory Import Result

/// Summary of a Markdown memory import operation.
public struct MemoryImportResult: Sendable, Codable, Equatable {
    public let topicsImported: Int
    public let factsImported: Int
    public let isSuccess: Bool
    public let message: String

    public init(topicsImported: Int, factsImported: Int, isSuccess: Bool = true, message: String = "") {
        self.topicsImported = topicsImported
        self.factsImported = factsImported
        self.isSuccess = isSuccess
        self.message = message
    }
}

// MARK: - SpaceMemoryInspectorManager

/// Coordinates the inspectable memory UI for Spaces:
/// - Extracts and categorizes topics and discrete memory blocks across memory tiers.
/// - Performs editing, deleting, and pausing of memory facts.
/// - Generates source provenance answering "why do you think that?".
/// - Enforces no-memory (incognito) session guards.
/// - Imports and exports memory sets in Markdown.
@Observable
@MainActor
public final class SpaceMemoryInspectorManager {
    public static let shared = SpaceMemoryInspectorManager()

    // Persistent/runtime state keyed by normalized workspace path
    private var pausedTopicsByWorkspace: [String: Set<String>] = [:]
    private var noMemoryModeByWorkspace: [String: Bool] = [:]

    private init() {}

    // MARK: - Path Resolution

    public func resolveWorkspacePath(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        return SpaceMemoryTierManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
    }

    private func pausedTopicsFileURL(for workspacePath: String) -> URL {
        let root = URL(fileURLWithPath: workspacePath)
        return root.appendingPathComponent(".apex", isDirectory: true).appendingPathComponent("paused_topics.json")
    }

    // MARK: - Topics & Blocks Extraction

    /// Scans all memory tiers for a Space and groups discrete facts into topics.
    public func loadTopics(space: SpaceModel? = nil, workspacePath: String? = nil) -> [MemoryTopicGroup] {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        loadPausedTopicsFromDisk(workspacePath: wsRoot)

        var allItems: [MemoryTopicItem] = []

        // Tier 1: Curated MEMORY.md
        let curatedPath = SpaceMemoryTierManager.shared.curatedMemoryPath(space: space, workspacePath: wsRoot)
        if FileManager.default.fileExists(atPath: curatedPath),
           let content = try? String(contentsOfFile: curatedPath, encoding: .utf8) {
            let rel = computeRelativePath(fullPath: curatedPath, workspaceRoot: wsRoot)
            let items = parseItems(from: content, filePath: curatedPath, relativePath: rel, tier: "curated", workspaceRoot: wsRoot)
            allItems.append(contentsOf: items)
        }

        // Tier 2: Daily Notes
        let dailyDir = SpaceMemoryTierManager.shared.dailyNotesDirectory(space: space, workspacePath: wsRoot)
        if let items = try? FileManager.default.contentsOfDirectory(at: dailyDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for item in items where item.pathExtension.lowercased() == "md" {
                if let content = try? String(contentsOfFile: item.path, encoding: .utf8) {
                    let rel = computeRelativePath(fullPath: item.path, workspaceRoot: wsRoot)
                    let noteItems = parseItems(from: content, filePath: item.path, relativePath: rel, tier: "daily", workspaceRoot: wsRoot)
                    allItems.append(contentsOf: noteItems)
                }
            }
        }

        // Tier 3: Persona / Behaviour
        let personaPath = SpaceMemoryTierManager.shared.personaPath(space: space, workspacePath: wsRoot)
        if FileManager.default.fileExists(atPath: personaPath),
           let content = try? String(contentsOfFile: personaPath, encoding: .utf8) {
            let rel = computeRelativePath(fullPath: personaPath, workspaceRoot: wsRoot)
            let personaItems = parseItems(from: content, filePath: personaPath, relativePath: rel, tier: "persona", workspaceRoot: wsRoot)
            allItems.append(contentsOf: personaItems)
        }

        // Tier 4: User Context
        let userPath = SpaceMemoryTierManager.shared.userContextPath(space: space, workspacePath: wsRoot)
        if FileManager.default.fileExists(atPath: userPath),
           let content = try? String(contentsOfFile: userPath, encoding: .utf8) {
            let rel = computeRelativePath(fullPath: userPath, workspaceRoot: wsRoot)
            let userItems = parseItems(from: content, filePath: userPath, relativePath: rel, tier: "user", workspaceRoot: wsRoot)
            allItems.append(contentsOf: userItems)
        }

        // Group items by normalized topic
        let pausedSet = pausedTopicsByWorkspace[wsRoot] ?? []
        var grouped: [String: [MemoryTopicItem]] = [:]
        for item in allItems {
            let t = item.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var copy = item
            copy.isPaused = pausedSet.contains(t)
            grouped[t, default: []].append(copy)
        }

        var result: [MemoryTopicGroup] = []
        for (topic, items) in grouped {
            let isPaused = pausedSet.contains(topic)
            result.append(MemoryTopicGroup(topic: topic, items: items, isPaused: isPaused))
        }

        result.sort { $0.topic < $1.topic }
        return result
    }

    private func parseItems(
        from content: String,
        filePath: String,
        relativePath: String,
        tier: String,
        workspaceRoot: String
    ) -> [MemoryTopicItem] {
        var items: [MemoryTopicItem] = []
        let lines = content.components(separatedBy: "\n")
        let dateFromPath = SpaceMemoryTierManager.extractDate(from: relativePath)
        let pausedSet = pausedTopicsByWorkspace[workspaceRoot] ?? []

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { continue }

            let lineNum = idx + 1
            let citation = extractCitation(from: trimmed) ?? "[\(relativePath):\(lineNum)]"
            let statement = extractStatement(from: trimmed)
            guard !statement.isEmpty else { continue }

            let key = extractTopicKey(from: trimmed)
            let citationDate = SpaceMemoryTierManager.extractDate(from: citation)
            let factDate = dateFromPath ?? citationDate ?? (tier == "curated" ? "curated" : todayDateString())
            let isPaused = pausedSet.contains(key.lowercased())

            let rationale: String
            switch tier {
            case "curated":
                rationale = "Stored in curated space memory (\(relativePath)) at line \(lineNum). Long-term persistent fact."
            case "daily":
                rationale = "Recorded during session activity on \(factDate) in \(relativePath) at line \(lineNum)."
            case "persona":
                rationale = "Configured in agent persona profile (\(relativePath)) at line \(lineNum)."
            case "user":
                rationale = "Defined in user preferences profile (\(relativePath)) at line \(lineNum)."
            default:
                rationale = "Recorded in \(relativePath) at line \(lineNum)."
            }

            let item = MemoryTopicItem(
                key: key,
                statement: statement,
                sourceCitation: citation,
                filePath: filePath,
                relativePath: relativePath,
                startLine: lineNum,
                endLine: lineNum,
                tier: tier,
                dateString: factDate,
                isPaused: isPaused,
                rawSourceSnippet: trimmed,
                provenanceRationale: rationale
            )
            items.append(item)
        }
        return items
    }

    // MARK: - Edit, Delete, Pause API

    /// Updates a memory topic item's statement and key in place within its source file.
    public func editItem(
        _ item: MemoryTopicItem,
        newKey: String,
        newStatement: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        guard FileManager.default.fileExists(atPath: item.filePath),
              let content = try? String(contentsOfFile: item.filePath, encoding: .utf8) else {
            throw NSError(domain: "SpaceMemoryInspectorManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source file not found: \(item.filePath)"])
        }

        var lines = content.components(separatedBy: "\n")
        let targetIndex = item.startLine - 1
        let updatedKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let updatedStatement = newStatement.trimmingCharacters(in: .whitespacesAndNewlines)

        let newLine = "- [\(item.relativePath):\(item.startLine)] \(updatedStatement) (key: \(updatedKey))"

        if targetIndex >= 0 && targetIndex < lines.count {
            lines[targetIndex] = newLine
        } else {
            // Locate line by statement content if line numbers drifted
            if let matchedIdx = lines.firstIndex(where: { $0.contains(item.statement) }) {
                lines[matchedIdx] = newLine
            } else {
                lines.append(newLine)
            }
        }

        let newContent = lines.joined(separator: "\n")
        try newContent.write(toFile: item.filePath, atomically: true, encoding: .utf8)

        // If old key was paused and key changed, migrate pause status
        if isTopicPaused(item.key, workspacePath: wsRoot) && item.key.lowercased() != updatedKey {
            resumeTopic(item.key, workspacePath: wsRoot)
            pauseTopic(updatedKey, workspacePath: wsRoot)
        }

        HybridMemoryRetriever.shared.clearCache()
        RunTraceManager.shared.recordMemoryWrite(tier: item.tier, path: item.filePath, bytesWritten: newContent.utf8.count, detail: "Edited memory topic \(updatedKey)")
        AppLog.info(.app, "Edited memory topic item '\(updatedKey)' in \(item.relativePath)")
    }

    /// Deletes a memory item from its source file.
    public func deleteItem(
        _ item: MemoryTopicItem,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: item.filePath),
              let content = try? String(contentsOfFile: item.filePath, encoding: .utf8) else {
            return
        }

        var lines = content.components(separatedBy: "\n")
        let targetIndex = item.startLine - 1
        if targetIndex >= 0 && targetIndex < lines.count && lines[targetIndex].contains(item.statement) {
            lines.remove(at: targetIndex)
        } else if let matchedIdx = lines.firstIndex(where: { $0.contains(item.statement) }) {
            lines.remove(at: matchedIdx)
        }

        let newContent = lines.joined(separator: "\n")
        try newContent.write(toFile: item.filePath, atomically: true, encoding: .utf8)

        HybridMemoryRetriever.shared.clearCache()
        RunTraceManager.shared.recordMemoryWrite(tier: item.tier, path: item.filePath, bytesWritten: newContent.utf8.count, detail: "Deleted memory topic item '\(item.key)'")
        AppLog.info(.app, "Deleted memory item '\(item.key)' from \(item.relativePath)")
    }

    /// Deletes all memory items belonging to a topic.
    public func deleteTopic(
        _ topic: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let groups = loadTopics(space: space, workspacePath: wsRoot)
        guard let group = groups.first(where: { $0.topic.lowercased() == topic.lowercased() }) else {
            return
        }

        for item in group.items {
            try? deleteItem(item, space: space, workspacePath: wsRoot)
        }

        resumeTopic(topic, workspacePath: wsRoot)
        HybridMemoryRetriever.shared.clearCache()
        AppLog.info(.app, "Deleted entire topic '\(topic)' across all memory tiers")
    }

    // MARK: - Pausing & Retrieval Gating

    /// Pauses a topic, excluding all its facts from hybrid search and agent retrieval.
    public func pauseTopic(
        _ topic: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        loadPausedTopicsFromDisk(workspacePath: wsRoot)

        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }

        var current = pausedTopicsByWorkspace[wsRoot] ?? []
        current.insert(t)
        pausedTopicsByWorkspace[wsRoot] = current
        savePausedTopicsToDisk(workspacePath: wsRoot)

        HybridMemoryRetriever.shared.clearCache()
        AppLog.info(.app, "Paused memory topic '\(t)' in workspace \(wsRoot)")
    }

    /// Resumes a paused topic, re-enabling it for retrieval.
    public func resumeTopic(
        _ topic: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        loadPausedTopicsFromDisk(workspacePath: wsRoot)

        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return }

        var current = pausedTopicsByWorkspace[wsRoot] ?? []
        current.remove(t)
        pausedTopicsByWorkspace[wsRoot] = current
        savePausedTopicsToDisk(workspacePath: wsRoot)

        HybridMemoryRetriever.shared.clearCache()
        AppLog.info(.app, "Resumed memory topic '\(t)' in workspace \(wsRoot)")
    }

    /// Checks if a topic is currently paused.
    public func isTopicPaused(
        _ topic: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) -> Bool {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        loadPausedTopicsFromDisk(workspacePath: wsRoot)
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return pausedTopicsByWorkspace[wsRoot]?.contains(t) == true
    }

    /// Checks if a memory chunk belongs to any paused topic.
    public func isChunkPaused(
        _ chunk: MemoryChunk,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) -> Bool {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        loadPausedTopicsFromDisk(workspacePath: wsRoot)
        guard let pausedSet = pausedTopicsByWorkspace[wsRoot], !pausedSet.isEmpty else {
            return false
        }

        // 1. Check explicit topic/key tags in chunk content
        let lines = chunk.content.components(separatedBy: "\n")
        for line in lines {
            let key = extractTopicKey(from: line).lowercased()
            if pausedSet.contains(key) {
                return true
            }
        }

        // 2. Check token overlap with paused topic names
        let tokens = Set(chunk.tokens.map { $0.lowercased() })
        for paused in pausedSet {
            let pausedTokens = paused.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 }
            if !pausedTokens.isEmpty && pausedTokens.allSatisfy({ tokens.contains($0) }) {
                return true
            }
        }

        return false
    }

    private func loadPausedTopicsFromDisk(workspacePath: String) {
        guard pausedTopicsByWorkspace[workspacePath] == nil else { return }
        let fileURL = pausedTopicsFileURL(for: workspacePath)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            pausedTopicsByWorkspace[workspacePath] = []
            return
        }
        pausedTopicsByWorkspace[workspacePath] = Set(list.map { $0.lowercased() })
    }

    private func savePausedTopicsToDisk(workspacePath: String) {
        let fileURL = pausedTopicsFileURL(for: workspacePath)
        let list = Array(pausedTopicsByWorkspace[workspacePath] ?? [])
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - "Why Do You Think That?" Source Panel

    /// Constructs provenance evidence answering "Why do you think that?" for a memory fact.
    public func provenance(for item: MemoryTopicItem) -> MemoryProvenance {
        let lineRangeStr: String
        if item.startLine == item.endLine {
            lineRangeStr = "Line \(item.startLine)"
        } else {
            lineRangeStr = "Lines \(item.startLine)–\(item.endLine)"
        }

        let answer = """
        The agent holds this belief because it was explicitly recorded in \(item.relativePath) on \(item.dateString) at \(lineRangeStr).
        Source Citation: \(item.sourceCitation)
        Tier: \(item.tier.capitalized) Memory
        Verbatim Source Text: "\(item.rawSourceSnippet)"
        """

        return MemoryProvenance(
            key: item.key,
            statement: item.statement,
            sourceCitation: item.sourceCitation,
            filePath: item.filePath,
            relativePath: item.relativePath,
            lineRange: lineRangeStr,
            tier: item.tier,
            dateRecorded: item.dateString,
            verbatimSourceSnippet: item.rawSourceSnippet,
            provenanceAnswer: answer
        )
    }

    // MARK: - Incognito / No-Memory Mode

    /// Sets incognito / no-memory mode for a space. When active, sessions will not write to disk.
    public func setNoMemoryMode(
        _ enabled: Bool,
        for space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        noMemoryModeByWorkspace[wsRoot] = enabled
        AppLog.info(.app, "No-memory mode set to \(enabled) for workspace \(wsRoot)")
    }

    /// Checks if no-memory mode is currently active.
    public func isNoMemoryModeEnabled(
        for space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) -> Bool {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        return noMemoryModeByWorkspace[wsRoot] ?? false
    }

    // MARK: - Markdown Import & Export

    /// Exports all memory topics and blocks into a clean, human-readable and re-importable Markdown document.
    public func exportMarkdown(
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) -> String {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let groups = loadTopics(space: space, workspacePath: wsRoot)
        let spaceName = space?.name ?? "Space"

        var md = "# Space Memory Export: \(spaceName)\n"
        md += "Exported At: \(ISO8601DateFormatter().string(from: Date()))\n"
        md += "Workspace: \(wsRoot)\n"
        md += "Total Topics: \(groups.count)\n\n"

        for group in groups {
            let status = group.isPaused ? "Paused" : "Active"
            md += "## Topic: \(group.topic) (Status: \(status))\n"
            for item in group.items {
                md += "- \(item.sourceCitation) \(item.statement) (key: \(item.key), tier: \(item.tier), date: \(item.dateString))\n"
            }
            md += "\n"
        }

        return md
    }

    /// Imports a Markdown memory export, restoring topics and facts into MEMORY.md and updating pause status.
    @discardableResult
    public func importMarkdown(
        _ markdown: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws -> MemoryImportResult {
        let wsRoot = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let lines = markdown.components(separatedBy: "\n")

        var currentTopic: String? = nil
        var currentIsPaused = false
        var factsByTopic: [String: [(statement: String, citation: String, key: String, tier: String, date: String)]] = [:]
        var pausedToRestore: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Topic:") {
                // Header pattern: ## Topic: <name> (Status: <status>)
                let raw = trimmed.replacingOccurrences(of: "## Topic:", with: "").trimmingCharacters(in: .whitespaces)
                let parts = raw.components(separatedBy: "(Status:")
                let topicName = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "general"
                let isPaused = parts.count > 1 && parts[1].localizedCaseInsensitiveContains("Paused")
                currentTopic = topicName
                currentIsPaused = isPaused
                if isPaused {
                    pausedToRestore.insert(topicName)
                }
                continue
            } else if trimmed.hasPrefix("### ") {
                let topicName = trimmed.replacingOccurrences(of: "### ", with: "").trimmingCharacters(in: .whitespaces).lowercased()
                currentTopic = topicName
                currentIsPaused = false
                continue
            }

            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { continue }

            let citation = extractCitation(from: trimmed) ?? "[MEMORY.md:import]"
            let statement = extractStatement(from: trimmed)
            let key = currentTopic ?? extractTopicKey(from: trimmed)
            guard !statement.isEmpty else { continue }

            factsByTopic[key, default: []].append((
                statement: statement,
                citation: citation,
                key: key,
                tier: "curated",
                date: todayDateString()
            ))

            if currentIsPaused {
                pausedToRestore.insert(key)
            }
        }

        // Rebuild curated MEMORY.md
        var newCurated = "# Space Curated Memory\n\n## Key Facts\n"
        var lineIndex = 4
        var totalFacts = 0

        for (topic, facts) in factsByTopic.sorted(by: { $0.key < $1.key }) {
            for f in facts {
                newCurated += "- [MEMORY.md:\(lineIndex)] \(f.statement) (key: \(topic))\n"
                lineIndex += 1
                totalFacts += 1
            }
        }

        let curatedPath = SpaceMemoryTierManager.shared.curatedMemoryPath(space: space, workspacePath: wsRoot)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: curatedPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try newCurated.write(toFile: curatedPath, atomically: true, encoding: .utf8)

        // Restore paused topics
        for paused in pausedToRestore {
            pauseTopic(paused, workspacePath: wsRoot)
        }

        HybridMemoryRetriever.shared.clearCache()
        RunTraceManager.shared.recordMemoryWrite(tier: "curated", path: curatedPath, bytesWritten: newCurated.utf8.count, detail: "Imported memory set from Markdown")

        return MemoryImportResult(
            topicsImported: factsByTopic.keys.count,
            factsImported: totalFacts,
            isSuccess: true,
            message: "Successfully imported \(factsByTopic.keys.count) topics and \(totalFacts) facts."
        )
    }

    // MARK: - Helper Parsing Methods

    private func extractCitation(from line: String) -> String? {
        let pattern = #"\[([^\]]+:\d+(?:-\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = regex.firstMatch(in: line, options: [], range: range),
           let r = Range(match.range, in: line) {
            return String(line[r])
        }
        return nil
    }

    private func extractTopicKey(from text: String) -> String {
        // Pattern 1: (key: <key>) or (topic: <topic>)
        let keyPattern = #"\((?:key|topic):\s*([a-zA-Z0-9_\-]+)\)"#
        if let regex = try? NSRegularExpression(pattern: keyPattern, options: .caseInsensitive) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let r = Range(match.range(at: 1), in: text) {
                return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
        }

        // Pattern 2: key: value
        let colonPattern = #"^\s*[-*]?\s*([a-zA-Z0-9_\-]+)\s*:\s+"#
        if let regex = try? NSRegularExpression(pattern: colonPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, options: [], range: range),
               let r = Range(match.range(at: 1), in: text) {
                let candidate = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if candidate != "fact" && candidate != "decision" && candidate != "note" {
                    return candidate
                }
            }
        }

        // Fallback: derive slug from first words
        let cleaned = text
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-* \t"))
        let words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        if !words.isEmpty {
            return words.prefix(3).joined(separator: "_").lowercased()
        }
        return "general"
    }

    private func extractStatement(from line: String) -> String {
        var s = line
        // Remove leading bullet
        if s.hasPrefix("-") || s.hasPrefix("*") {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Remove citation e.g. [MEMORY.md:12]
        s = s.replacingOccurrences(of: #"\[[^\]]+:\d+(?:-\d+)?\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // Remove trailing (key: ...) or (topic: ...)
        s = s.replacingOccurrences(of: #"\((?:key|topic):\s*[a-zA-Z0-9_\-]+\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // Remove trailing (tier: ..., date: ...)
        s = s.replacingOccurrences(of: #"\(tier:[^)]+\)"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func computeRelativePath(fullPath: String, workspaceRoot: String) -> String {
        let root = (URL(fileURLWithPath: workspaceRoot).resolvingSymlinksInPath().path as NSString).standardizingPath
        let full = (URL(fileURLWithPath: fullPath).resolvingSymlinksInPath().path as NSString).standardizingPath
        if full.hasPrefix(root) {
            var rel = String(full.dropFirst(root.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return (full as NSString).lastPathComponent
    }

    private func todayDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: Date())
    }
}
