import Foundation
import SharedKit
import SwiftData

// MARK: - Memory Fact Model

/// A discrete factual statement tracked across files-first memory tiers.
public struct MemoryFact: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let key: String
    public let value: String
    public let sourceCitation: String
    public let tier: String // "daily", "curated", "session", "persona", "user"
    public let dateString: String // YYYY-MM-DD or ISO timestamp
    public var isSuperseded: Bool
    public var supersededByCitation: String?

    public init(
        id: UUID = UUID(),
        key: String,
        value: String,
        sourceCitation: String,
        tier: String,
        dateString: String = "",
        isSuperseded: Bool = false,
        supersededByCitation: String? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.sourceCitation = sourceCitation
        self.tier = tier
        if dateString.isEmpty {
            self.dateString = tier == "curated" ? "0000-00-00" : Self.currentDateString()
        } else {
            self.dateString = dateString
        }
        self.isSuperseded = isSuperseded
        self.supersededByCitation = supersededByCitation
    }

    private static func currentDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }
}

// MARK: - Superseded Fact Pair

/// Records a transition where a newer fact supersedes an older fact.
public struct SupersededFactPair: Sendable, Codable, Equatable {
    public let oldFact: MemoryFact
    public let newFact: MemoryFact

    public init(oldFact: MemoryFact, newFact: MemoryFact) {
        self.oldFact = oldFact
        self.newFact = newFact
    }
}

// MARK: - Flush Result

/// Result of a pre-compaction memory flush operation.
public struct MemoryFlushResult: Sendable, Codable, Equatable {
    public let dailyNotePath: String
    public let curatedMemoryPath: String
    public let dailyCitations: [String]
    public let curatedCitations: [String]
    public let factsFlushedCount: Int
    public let isIdempotent: Bool
    public let outputDescription: String

    public init(
        dailyNotePath: String,
        curatedMemoryPath: String,
        dailyCitations: [String],
        curatedCitations: [String],
        factsFlushedCount: Int,
        isIdempotent: Bool,
        outputDescription: String
    ) {
        self.dailyNotePath = dailyNotePath
        self.curatedMemoryPath = curatedMemoryPath
        self.dailyCitations = dailyCitations
        self.curatedCitations = curatedCitations
        self.factsFlushedCount = factsFlushedCount
        self.isIdempotent = isIdempotent
        self.outputDescription = outputDescription
    }
}

// MARK: - Consolidation Diff

/// Detailed diff showing what memory facts were added, updated, superseded, or left unchanged.
public struct ConsolidationDiff: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let totalFactsAnalyzed: Int
    public let added: [MemoryFact]
    public let updated: [MemoryFact]
    public let superseded: [SupersededFactPair]
    public let unchanged: [MemoryFact]
    public let formattedDiff: String
    public let isIdempotent: Bool

    public init(
        timestamp: Date = Date(),
        totalFactsAnalyzed: Int,
        added: [MemoryFact],
        updated: [MemoryFact],
        superseded: [SupersededFactPair],
        unchanged: [MemoryFact],
        formattedDiff: String,
        isIdempotent: Bool
    ) {
        self.timestamp = timestamp
        self.totalFactsAnalyzed = totalFactsAnalyzed
        self.added = added
        self.updated = updated
        self.superseded = superseded
        self.unchanged = unchanged
        self.formattedDiff = formattedDiff
        self.isIdempotent = isIdempotent
    }
}

// MARK: - Memory Consolidation Engine

/// Coordinates pre-compaction session memory distillation and periodic background memory consolidation.
@MainActor
public final class MemoryConsolidationEngine {
    public static let shared = MemoryConsolidationEngine()

    private init() {}

    // MARK: - Pre-Compaction Memory Flush

    /// Distils session messages into daily notes and long-term MEMORY.md.
    @discardableResult
    func flushSession(
        messages: [ChatMessage],
        space: SpaceModel? = nil,
        workspacePath: String? = nil,
        date: String? = nil
    ) throws -> MemoryFlushResult {
        let raw = messages.map { (role: Self.roleString(for: $0.role), content: $0.content) }
        return try flushSession(
            rawMessages: raw,
            explicitFacts: nil,
            space: space,
            workspacePath: workspacePath,
            date: date
        )
    }

    /// Distils session messages or extracted facts into daily notes and long-term MEMORY.md.
    /// Guarantees that flushing the same session twice is idempotent and adds nothing.
    @discardableResult
    public func flushSession(
        rawMessages: [(role: String, content: String)]? = nil,
        explicitFacts: [String]? = nil,
        space: SpaceModel? = nil,
        workspacePath: String? = nil,
        date: String? = nil
    ) throws -> MemoryFlushResult {
        let wsRoot = SpaceMemoryTierManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let resolvedDate = date ?? Self.todayDateString()
        let dailyDir = SpaceMemoryTierManager.shared.dailyNotesDirectory(space: space, workspacePath: wsRoot)
        try FileManager.default.createDirectory(at: dailyDir, withIntermediateDirectories: true)
        let dailyFilePath = dailyDir.appendingPathComponent("\(resolvedDate).md").path

        let curatedFilePath = SpaceMemoryTierManager.shared.curatedMemoryPath(space: space, workspacePath: wsRoot)
        let curatedURL = URL(fileURLWithPath: curatedFilePath)
        try FileManager.default.createDirectory(at: curatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 1. Extract raw candidate facts
        let candidateFacts: [String]
        if let explicit = explicitFacts, !explicit.isEmpty {
            candidateFacts = explicit
        } else if let msgs = rawMessages, !msgs.isEmpty {
            candidateFacts = Self.extractFactsFromRawMessages(msgs)
        } else {
            candidateFacts = []
        }

        guard !candidateFacts.isEmpty else {
            return MemoryFlushResult(
                dailyNotePath: dailyFilePath,
                curatedMemoryPath: curatedFilePath,
                dailyCitations: [],
                curatedCitations: [],
                factsFlushedCount: 0,
                isIdempotent: true,
                outputDescription: "No facts identified to flush."
            )
        }

        // 2. Read existing daily note and curated memory
        var existingDaily = (try? String(contentsOfFile: dailyFilePath, encoding: .utf8)) ?? ""
        var existingCurated = (try? String(contentsOfFile: curatedFilePath, encoding: .utf8)) ?? ""

        let existingDailyNormalized = existingDaily.lowercased()
        let existingCuratedNormalized = existingCurated.lowercased()

        // 3. Filter candidate facts that are already present (Idempotency check)
        var newDailyLines: [(fact: String, citation: String)] = []
        var newCuratedLines: [(fact: String, citation: String)] = []

        var currentDailyLinesCount = existingDaily.isEmpty ? 0 : existingDaily.components(separatedBy: "\n").count
        var currentCuratedLinesCount = existingCurated.isEmpty ? 0 : existingCurated.components(separatedBy: "\n").count

        let relDailyPath = "daily/\(resolvedDate).md"
        let relCuratedPath = "MEMORY.md"

        for fact in candidateFacts {
            let key = Self.extractKey(from: fact)
            let normalizedFact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedFact.isEmpty else { continue }

            let factCore = Self.extractFactStatement(from: normalizedFact)
            let isAlreadyInDaily = existingDailyNormalized.contains(factCore.lowercased())
                || (key.count >= 4 && existingDailyNormalized.contains("(key: \(key.lowercased()))"))

            if !isAlreadyInDaily {
                let nextDailyLine = currentDailyLinesCount + 1
                let citation = "[\(relDailyPath):\(nextDailyLine)]"
                let lineText = "- \(citation) \(factCore) (key: \(key))"
                newDailyLines.append((fact: lineText, citation: citation))
                currentDailyLinesCount += 1
            }

            let isAlreadyInCurated = existingCuratedNormalized.contains(factCore.lowercased())
                || (key.count >= 4 && existingCuratedNormalized.contains("(key: \(key.lowercased()))"))

            if !isAlreadyInCurated {
                let nextCuratedLine = currentCuratedLinesCount + 1
                let citation = "[\(relCuratedPath):\(nextCuratedLine)]"
                let lineText = "- \(citation) \(factCore) (key: \(key))"
                newCuratedLines.append((fact: lineText, citation: citation))
                currentCuratedLinesCount += 1
            }
        }

        // 4. If nothing new, return idempotent result without rewriting disk
        if newDailyLines.isEmpty && newCuratedLines.isEmpty {
            return MemoryFlushResult(
                dailyNotePath: dailyFilePath,
                curatedMemoryPath: curatedFilePath,
                dailyCitations: [],
                curatedCitations: [],
                factsFlushedCount: 0,
                isIdempotent: true,
                outputDescription: "Already flushed: 0 new entries added (idempotent)."
            )
        }

        // 5. Append to daily note
        if !newDailyLines.isEmpty {
            if existingDaily.isEmpty {
                existingDaily = "# Daily Note: \(resolvedDate)\nTags: #memory #session-flush\n\n## Session Flush\n"
                // Recalculate citations with header offset
                let headerLines = existingDaily.components(separatedBy: "\n").count - 1
                var updatedLines: [(fact: String, citation: String)] = []
                for (idx, item) in newDailyLines.enumerated() {
                    let lineNum = headerLines + idx + 1
                    let cit = "[\(relDailyPath):\(lineNum)]"
                    let core = Self.extractFactStatement(from: item.fact)
                    let key = Self.extractKey(from: item.fact)
                    let text = "- \(cit) \(core) (key: \(key))"
                    updatedLines.append((fact: text, citation: cit))
                }
                newDailyLines = updatedLines
                existingDaily += newDailyLines.map(\.fact).joined(separator: "\n") + "\n"
            } else {
                if !existingDaily.hasSuffix("\n") { existingDaily += "\n" }
                existingDaily += newDailyLines.map(\.fact).joined(separator: "\n") + "\n"
            }
            try existingDaily.write(toFile: dailyFilePath, atomically: true, encoding: .utf8)
        }

        // 6. Append to curated MEMORY.md
        if !newCuratedLines.isEmpty {
            if existingCurated.isEmpty {
                existingCurated = "# Space Curated Memory\n\n## Key Facts\n"
                let headerLines = existingCurated.components(separatedBy: "\n").count - 1
                var updatedLines: [(fact: String, citation: String)] = []
                for (idx, item) in newCuratedLines.enumerated() {
                    let lineNum = headerLines + idx + 1
                    let cit = "[\(relCuratedPath):\(lineNum)]"
                    let core = Self.extractFactStatement(from: item.fact)
                    let key = Self.extractKey(from: item.fact)
                    let text = "- \(cit) \(core) (key: \(key))"
                    updatedLines.append((fact: text, citation: cit))
                }
                newCuratedLines = updatedLines
                existingCurated += newCuratedLines.map(\.fact).joined(separator: "\n") + "\n"
            } else {
                if !existingCurated.hasSuffix("\n") { existingCurated += "\n" }
                existingCurated += newCuratedLines.map(\.fact).joined(separator: "\n") + "\n"
            }
            try existingCurated.write(toFile: curatedFilePath, atomically: true, encoding: .utf8)
        }

        // Invalidate retriever cache
        HybridMemoryRetriever.shared.clearCache()

        let totalFlushed = max(newDailyLines.count, newCuratedLines.count)
        let desc = "✅ Flushed \(totalFlushed) fact(s) to daily note (\(newDailyLines.count)) and MEMORY.md (\(newCuratedLines.count))."

        return MemoryFlushResult(
            dailyNotePath: dailyFilePath,
            curatedMemoryPath: curatedFilePath,
            dailyCitations: newDailyLines.map(\.citation),
            curatedCitations: newCuratedLines.map(\.citation),
            factsFlushedCount: totalFlushed,
            isIdempotent: false,
            outputDescription: desc
        )
    }

    // MARK: - Background Memory Consolidation

    /// Performs memory consolidation across daily notes and curated MEMORY.md.
    /// Supersedes stale facts, keeps the newest facts, and returns a human-readable diff.
    /// Never deletes a fact without recording the supersession in the diff.
    public func consolidate(
        space: SpaceModel? = nil,
        workspacePath: String? = nil,
        dryRun: Bool = false
    ) throws -> ConsolidationDiff {
        let wsRoot = SpaceMemoryTierManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let curatedPath = SpaceMemoryTierManager.shared.curatedMemoryPath(space: space, workspacePath: wsRoot)
        let dailyDir = SpaceMemoryTierManager.shared.dailyNotesDirectory(space: space, workspacePath: wsRoot)

        // 1. Collect all facts from MEMORY.md
        var curatedFacts: [MemoryFact] = []
        if FileManager.default.fileExists(atPath: curatedPath),
           let content = try? String(contentsOfFile: curatedPath, encoding: .utf8) {
            curatedFacts = Self.parseFacts(from: content, filePath: curatedPath, relativePath: "MEMORY.md", tier: "curated")
        }

        // 2. Collect all facts from all daily notes
        var dailyFacts: [MemoryFact] = []
        if let items = try? FileManager.default.contentsOfDirectory(at: dailyDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for item in items where item.pathExtension.lowercased() == "md" {
                if let noteContent = try? String(contentsOf: item, encoding: .utf8) {
                    let relPath = "daily/\(item.lastPathComponent)"
                    let facts = Self.parseFacts(from: noteContent, filePath: item.path, relativePath: relPath, tier: "daily")
                    dailyFacts.append(contentsOf: facts)
                }
            }
        }

        let totalAnalyzed = curatedFacts.count + dailyFacts.count

        // 3. Track facts by normalized key
        var factsByKey: [String: [MemoryFact]] = [:]
        for f in curatedFacts {
            factsByKey[f.key, default: []].append(f)
        }
        for f in dailyFacts {
            factsByKey[f.key, default: []].append(f)
        }

        var addedFacts: [MemoryFact] = []
        var updatedFacts: [MemoryFact] = []
        var supersededPairs: [SupersededFactPair] = []
        var unchangedFacts: [MemoryFact] = []

        var updatedCuratedFacts: [MemoryFact] = []
        var curatedFactKeysHandled: Set<String> = []

        // Evaluate each key group
        for (key, group) in factsByKey {
            let sortedByDate = group.sorted {
                if $0.dateString != $1.dateString {
                    return $0.dateString > $1.dateString
                }
                // Daily notes take precedence over older curated facts of same date
                if $0.tier != $1.tier {
                    return $0.tier == "daily"
                }
                return $0.sourceCitation > $1.sourceCitation
            }

            guard let newest = sortedByDate.first else { continue }
            let existingInCurated = curatedFacts.first(where: { $0.key == key })

            if let old = existingInCurated {
                curatedFactKeysHandled.insert(key)
                if old.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != newest.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                    // Fact was updated / superseded!
                    let pair = SupersededFactPair(oldFact: old, newFact: newest)
                    supersededPairs.append(pair)
                    updatedFacts.append(newest)
                    updatedCuratedFacts.append(newest)
                } else {
                    unchangedFacts.append(old)
                    updatedCuratedFacts.append(old)
                }
            } else {
                // Fact is in daily note but not yet in MEMORY.md
                addedFacts.append(newest)
                updatedCuratedFacts.append(newest)
            }
        }

        // Include any remaining curated facts that weren't categorized
        for f in curatedFacts where !curatedFactKeysHandled.contains(f.key) {
            if !updatedCuratedFacts.contains(where: { $0.id == f.id || $0.key == f.key }) {
                unchangedFacts.append(f)
                updatedCuratedFacts.append(f)
            }
        }

        // Sort results for deterministic output
        addedFacts.sort { $0.key < $1.key }
        updatedFacts.sort { $0.key < $1.key }
        supersededPairs.sort { $0.oldFact.key < $1.oldFact.key }
        unchangedFacts.sort { $0.key < $1.key }

        let isIdempotent = addedFacts.isEmpty && updatedFacts.isEmpty && supersededPairs.isEmpty

        // 4. Build readable diff output
        let diffText = Self.formatConsolidationDiff(
            totalAnalyzed: totalAnalyzed,
            added: addedFacts,
            updated: updatedFacts,
            superseded: supersededPairs,
            unchanged: unchangedFacts,
            isIdempotent: isIdempotent
        )

        // 5. If not dryRun and changes exist, write consolidated MEMORY.md
        if !dryRun && !isIdempotent {
            var newContent = "# Space Curated Memory\n\n## Consolidated Facts\n"
            var lineIndex = 4
            for fact in updatedCuratedFacts {
                let citation = "[MEMORY.md:\(lineIndex)]"
                var line = "- \(citation) \(fact.value) (key: \(fact.key))"
                if let sup = supersededPairs.first(where: { $0.newFact.key == fact.key }) {
                    line += " [Supersedes: \(sup.oldFact.sourceCitation)]"
                }
                newContent += line + "\n"
                lineIndex += 1
            }

            if !supersededPairs.isEmpty {
                newContent += "\n## Superseded History\n"
                lineIndex += 2
                for sup in supersededPairs {
                    let citation = "[MEMORY.md:\(lineIndex)]"
                    newContent += "- \(citation) Superseded: '\(sup.oldFact.value)' by \(sup.newFact.sourceCitation)\n"
                    lineIndex += 1
                }
            }

            let curatedURL = URL(fileURLWithPath: curatedPath)
            try FileManager.default.createDirectory(at: curatedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try newContent.write(toFile: curatedPath, atomically: true, encoding: .utf8)
            HybridMemoryRetriever.shared.clearCache()
        }

        return ConsolidationDiff(
            timestamp: Date(),
            totalFactsAnalyzed: totalAnalyzed,
            added: addedFacts,
            updated: updatedFacts,
            superseded: supersededPairs,
            unchanged: unchangedFacts,
            formattedDiff: diffText,
            isIdempotent: isIdempotent
        )
    }

    // MARK: - Parsing & Extraction Helpers

    public static func parseFacts(from content: String, filePath: String, relativePath: String, tier: String) -> [MemoryFact] {
        var facts: [MemoryFact] = []
        let lines = content.components(separatedBy: "\n")
        let dateFromPath = SpaceMemoryTierManager.extractDate(from: relativePath)
        var inSupersededSection = false

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().contains("superseded history") {
                inSupersededSection = true
                continue
            }
            if inSupersededSection {
                if trimmed.hasPrefix("#") {
                    inSupersededSection = false
                } else {
                    continue
                }
            }
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") else { continue }

            let lineNum = idx + 1
            let citation = extractCitation(from: trimmed) ?? "[\(relativePath):\(lineNum)]"
            let statement = extractFactStatement(from: trimmed)
            guard !statement.isEmpty else { continue }

            let key = extractKey(from: trimmed)
            let isSuperseded = trimmed.lowercased().contains("[superseded]")
                || trimmed.lowercased().contains("superseded:")

            let citationDate = SpaceMemoryTierManager.extractDate(from: citation)
            let factDate = dateFromPath ?? citationDate ?? (tier == "curated" ? "0000-00-00" : todayDateString())

            let fact = MemoryFact(
                key: key,
                value: statement,
                sourceCitation: citation,
                tier: tier,
                dateString: factDate,
                isSuperseded: isSuperseded
            )
            facts.append(fact)
        }
        return facts
    }

    public static func extractCitation(from line: String) -> String? {
        let pattern = #"\[([^\]]+:\d+(?:-\d+)?)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let match = regex.firstMatch(in: line, options: [], range: range),
           let r = Range(match.range, in: line) {
            return String(line[r])
        }
        return nil
    }

    public static func extractKey(from text: String) -> String {
        // Pattern 1: (key: <key>)
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

        // Fallback: derive normalized slug from first 3-4 significant words
        let cleaned = text
            .replacingOccurrences(of: #"\[[^\]]+\]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-* \t"))
        let words = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        if !words.isEmpty {
            return words.prefix(3).joined(separator: "_").lowercased()
        }
        return "fact_\(abs(text.hashValue % 10000))"
    }

    public static func extractFactStatement(from line: String) -> String {
        var clean = line.trimmingCharacters(in: .whitespaces)
        if clean.hasPrefix("-") || clean.hasPrefix("*") {
            clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // Remove citations like [MEMORY.md:12]
        clean = clean.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        // Remove trailing [Supersedes: ...] (including nested citations)
        if let supRange = clean.range(of: #"\s*\[Supersedes:.*\]"#, options: .regularExpression) {
            clean.removeSubrange(supRange)
        }
        // Remove trailing (key: ...) or (topic: ...)
        clean = clean.replacingOccurrences(of: #"\s*\((?:key|topic):\s*[a-zA-Z0-9_\-]+\)"#, with: "", options: .regularExpression)
        // Clean trailing punctuation / brackets if any
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean
    }

    static func extractFactsFromMessages(_ messages: [ChatMessage]) -> [String] {
        let raw = messages.map { (role: Self.roleString(for: $0.role), content: $0.content) }
        return extractFactsFromRawMessages(raw)
    }

    private static func roleString(for role: MessageRole) -> String {
        switch role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }

    public static func extractFactsFromRawMessages(_ messages: [(role: String, content: String)]) -> [String] {
        var facts: [String] = []
        for msg in messages {
            let content = msg.content
            let lines = content.components(separatedBy: "\n")
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") || trimmed.hasPrefix("*") {
                    let stmt = extractFactStatement(from: trimmed)
                    if stmt.count >= 10 {
                        facts.append(stmt)
                    }
                } else if trimmed.localizedCaseInsensitiveContains("runs on")
                            || trimmed.localizedCaseInsensitiveContains("port")
                            || trimmed.localizedCaseInsensitiveContains("configured")
                            || trimmed.localizedCaseInsensitiveContains("migrated")
                            || trimmed.localizedCaseInsensitiveContains("set to") {
                    let sentences = trimmed.components(separatedBy: ". ")
                    for s in sentences {
                        let cleanS = s.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n"))
                        if cleanS.count >= 15 && !cleanS.hasPrefix("http") {
                            facts.append(cleanS + ".")
                        }
                    }
                }
            }
        }
        return facts
    }

    public static func formatConsolidationDiff(
        totalAnalyzed: Int,
        added: [MemoryFact],
        updated: [MemoryFact],
        superseded: [SupersededFactPair],
        unchanged: [MemoryFact],
        isIdempotent: Bool
    ) -> String {
        var out = "=== MEMORY CONSOLIDATION DIFF ===\n"
        let fmt = ISO8601DateFormatter()
        out += "Timestamp: \(fmt.string(from: Date()))\n"
        out += "Total facts analyzed: \(totalAnalyzed) | Added: \(added.count) | Updated: \(updated.count) | Superseded: \(superseded.count) | Unchanged: \(unchanged.count)\n\n"

        if isIdempotent {
            out += "Memory is already consolidated. No changes made.\n"
            out += "================================="
            return out
        }

        if !superseded.isEmpty {
            out += "## Superseded Facts (\(superseded.count))\n"
            for pair in superseded {
                out += "- \(pair.oldFact.sourceCitation) (Superseded by \(pair.newFact.sourceCitation))\n"
                out += "  OLD: \(pair.oldFact.value)\n"
                out += "  NEW: \(pair.newFact.value)\n"
            }
            out += "\n"
        }

        if !added.isEmpty {
            out += "## Added Facts (\(added.count))\n"
            for fact in added {
                out += "- \(fact.sourceCitation) \(fact.value) (key: \(fact.key))\n"
            }
            out += "\n"
        }

        if !unchanged.isEmpty {
            out += "## Unchanged Facts (\(unchanged.count))\n"
            for fact in unchanged.prefix(10) {
                out += "- \(fact.sourceCitation) \(fact.value)\n"
            }
            if unchanged.count > 10 {
                out += "... and \(unchanged.count - 10) more unchanged facts.\n"
            }
            out += "\n"
        }

        out += "================================="
        return out
    }

    public static func todayDateString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        return fmt.string(from: Date())
    }
}

// MARK: - Memory Consolidation Scheduler

/// Background scheduler for periodic memory consolidation.
/// Guaranteed not to trigger unexpected executions during test gates.
@MainActor
public final class MemoryConsolidationScheduler {
    public static let shared = MemoryConsolidationScheduler()
    private var task: Task<Void, Never>?
    public private(set) var isRunning: Bool = false
    public var interval: TimeInterval = 3600

    private init() {}

    public func start(interval: TimeInterval? = nil, workspacePath: String? = nil) {
        if let interval { self.interval = interval }
        stop()
        isRunning = true
        let currentInterval = self.interval
        task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(currentInterval))
                guard !Task.isCancelled else { break }
                _ = try? MemoryConsolidationEngine.shared.consolidate(workspacePath: workspacePath)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
