import Foundation
import SharedKit
import SwiftData

// MARK: - Daily Note Data Structures

/// Represents an indexed daily note on disk.
public struct DailyNoteEntry: Identifiable, Sendable, Codable, Equatable {
    public var id: String { date }
    public let date: String // Formatted YYYY-MM-DD
    public let title: String
    public let filePath: String
    public let content: String
    public let tags: [String]
    public let modifiedAt: Date

    public init(
        date: String,
        title: String,
        filePath: String,
        content: String,
        tags: [String] = [],
        modifiedAt: Date = Date()
    ) {
        self.date = date
        self.title = title
        self.filePath = filePath
        self.content = content
        self.tags = tags
        self.modifiedAt = modifiedAt
    }
}

/// Search match result for daily note retrieval.
public struct DailyNoteMatch: Sendable, Equatable {
    public let date: String
    public let filePath: String
    public let title: String
    public let snippet: String
    public let score: Double

    public init(
        date: String,
        filePath: String,
        title: String,
        snippet: String,
        score: Double
    ) {
        self.date = date
        self.filePath = filePath
        self.title = title
        self.snippet = snippet
        self.score = score
    }
}

// MARK: - SpaceMemoryTierManager

/// Coordinates human-editable and git-versionable files-first memory tiers:
/// 1. Per-Space curated MEMORY.md
/// 2. Indexed daily notes (daily/YYYY-MM-DD.md)
/// 3. Persona / Behaviour file (PERSONA.md)
/// 4. User profile & preferences file (USER.md)
@MainActor
public final class SpaceMemoryTierManager {
    public static let shared = SpaceMemoryTierManager()

    private init() {}

    // In-memory cache of indexed daily notes by directory path
    private var dailyNotesCache: [String: [DailyNoteEntry]] = [:]

    // MARK: - Workspace & Path Resolution

    /// Resolves the effective working directory path for a Space or explicit workspace.
    public func resolveWorkspacePath(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        if let explicit = workspacePath, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (explicit as NSString).expandingTildeInPath
        }
        if let space = space {
            return (space.workspacePath as NSString).expandingTildeInPath
        }
        if let active = SpaceManager.shared.activeSpace {
            return (active.workspacePath as NSString).expandingTildeInPath
        }
        return ApexAgentStoragePaths.directory("spaces/default/workspace").path
    }

    // MARK: - 1. Curated MEMORY.md Tier

    /// Returns the resolved file path for a Space's curated MEMORY.md.
    public func curatedMemoryPath(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        let root = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let rootURL = URL(fileURLWithPath: root)

        let candidatePaths = [
            rootURL.appendingPathComponent("MEMORY.md").path,
            rootURL.appendingPathComponent(".apex/MEMORY.md").path,
            rootURL.deletingLastPathComponent().appendingPathComponent("MEMORY.md").path
        ]

        for p in candidatePaths {
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }
        return rootURL.appendingPathComponent("MEMORY.md").path
    }

    /// Loads curated memory content from disk. Returns nil if missing or empty.
    public func loadCuratedMemory(for space: SpaceModel? = nil, workspacePath: String? = nil) -> String? {
        let path = curatedMemoryPath(space: space, workspacePath: workspacePath)
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves curated memory to disk at the Space's MEMORY.md location.
    public func saveCuratedMemory(_ content: String, for space: SpaceModel? = nil, workspacePath: String? = nil) throws {
        let path = curatedMemoryPath(space: space, workspacePath: workspacePath)
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        AppLog.info(.app, "Saved curated Space MEMORY.md at: \(path)")
    }

    // MARK: - 2. Persona / Behaviour Tier (PERSONA.md)

    /// Returns the resolved file path for persona/behaviour configuration.
    public func personaPath(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        let root = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let rootURL = URL(fileURLWithPath: root)

        let candidateNames = ["PERSONA.md", "BEHAVIOR.md", "persona.md", "behavior.md"]
        for name in candidateNames {
            let p = rootURL.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }

        // App-wide fallback
        let appWide = ApexAgentStoragePaths.apex.appendingPathComponent("PERSONA.md").path
        if FileManager.default.fileExists(atPath: appWide) {
            return appWide
        }

        return rootURL.appendingPathComponent("PERSONA.md").path
    }

    /// Loads persona content from disk. Returns nil if missing or empty.
    public func loadPersona(for space: SpaceModel? = nil, workspacePath: String? = nil) -> String? {
        let path = personaPath(space: space, workspacePath: workspacePath)
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves persona configuration to disk.
    public func savePersona(_ content: String, for space: SpaceModel? = nil, workspacePath: String? = nil) throws {
        let path = personaPath(space: space, workspacePath: workspacePath)
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        AppLog.info(.app, "Saved persona file at: \(path)")
    }

    // MARK: - 3. User Profile & Preferences Tier (USER.md)

    /// Returns the resolved file path for the user preferences file.
    public func userContextPath(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        let root = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let rootURL = URL(fileURLWithPath: root)

        let candidateNames = ["USER.md", "user.md", "USER_PROFILE.md"]
        for name in candidateNames {
            let p = rootURL.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) {
                return p
            }
        }

        // App-wide fallback
        let appWide = ApexAgentStoragePaths.apex.appendingPathComponent("USER.md").path
        if FileManager.default.fileExists(atPath: appWide) {
            return appWide
        }

        return rootURL.appendingPathComponent("USER.md").path
    }

    /// Loads user profile & preferences from disk. Returns nil if missing or empty.
    public func loadUserContext(for space: SpaceModel? = nil, workspacePath: String? = nil) -> String? {
        let path = userContextPath(space: space, workspacePath: workspacePath)
        guard FileManager.default.fileExists(atPath: path),
              let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Saves user profile & preferences to disk.
    public func saveUserContext(_ content: String, for space: SpaceModel? = nil, workspacePath: String? = nil) throws {
        let path = userContextPath(space: space, workspacePath: workspacePath)
        let fileURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        AppLog.info(.app, "Saved user context file at: \(path)")
    }

    // MARK: - 4. Indexed Daily Notes Tier

    /// Returns the directory URL where daily notes live for a Space or workspace.
    public func dailyNotesDirectory(space: SpaceModel? = nil, workspacePath: String? = nil) -> URL {
        let root = resolveWorkspacePath(space: space, workspacePath: workspacePath)
        let rootURL = URL(fileURLWithPath: root)

        let candidates = [
            rootURL.appendingPathComponent("daily", isDirectory: true),
            rootURL.appendingPathComponent("notes", isDirectory: true)
        ]

        for dir in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                return dir
            }
        }
        return candidates[0]
    }

    /// Scans, indexes, and caches all daily notes in the active daily notes directory.
    @discardableResult
    public func indexDailyNotes(space: SpaceModel? = nil, workspacePath: String? = nil) -> [DailyNoteEntry] {
        let dir = dailyNotesDirectory(space: space, workspacePath: workspacePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: dir.path) else {
            dailyNotesCache[dir.path] = []
            return []
        }

        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        var entries: [DailyNoteEntry] = []

        for fileURL in items where fileURL.pathExtension.lowercased() == "md" {
            guard let rawContent = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let baseName = fileURL.deletingPathExtension().lastPathComponent

            // Derive date: YYYY-MM-DD from filename or fallback to file creation/content
            let dateStr = Self.extractDate(from: baseName) ?? baseName
            let title = Self.extractTitle(from: rawContent, fallback: baseName)
            let tags = Self.extractTags(from: rawContent)
            let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()

            let entry = DailyNoteEntry(
                date: dateStr,
                title: title,
                filePath: fileURL.path,
                content: rawContent,
                tags: tags,
                modifiedAt: modDate
            )
            entries.append(entry)
        }

        // Sort descending by date
        entries.sort { $0.date > $1.date }
        dailyNotesCache[dir.path] = entries
        return entries
    }

    /// Saves a dated daily note to disk and updates the index.
    @discardableResult
    public func saveDailyNote(
        date: String,
        content: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil
    ) throws -> DailyNoteEntry {
        let dir = dailyNotesDirectory(space: space, workspacePath: workspacePath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let safeDate = Self.normalizeDateString(date)
        let targetFile = dir.appendingPathComponent("\(safeDate).md")
        try content.write(to: targetFile, atomically: true, encoding: .utf8)

        let title = Self.extractTitle(from: content, fallback: safeDate)
        let tags = Self.extractTags(from: content)
        let entry = DailyNoteEntry(
            date: safeDate,
            title: title,
            filePath: targetFile.path,
            content: content,
            tags: tags,
            modifiedAt: Date()
        )

        // Refresh cache
        _ = indexDailyNotes(space: space, workspacePath: workspacePath)
        AppLog.info(.app, "Saved daily note for '\(safeDate)' at: \(targetFile.path)")
        return entry
    }

    /// Retrieves a daily note for a specific date (YYYY-MM-DD).
    public func getDailyNote(date: String, space: SpaceModel? = nil, workspacePath: String? = nil) -> String? {
        let safeDate = Self.normalizeDateString(date)
        let dir = dailyNotesDirectory(space: space, workspacePath: workspacePath)
        let targetFile = dir.appendingPathComponent("\(safeDate).md")

        if FileManager.default.fileExists(atPath: targetFile.path),
           let content = try? String(contentsOf: targetFile, encoding: .utf8) {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback to indexed cache lookup
        let entries = indexDailyNotes(space: space, workspacePath: workspacePath)
        return entries.first(where: { $0.date == safeDate })?.content
    }

    /// Convenience to fetch today's daily note.
    public func getTodayDailyNote(space: SpaceModel? = nil, workspacePath: String? = nil) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let todayStr = formatter.string(from: Date())
        return getDailyNote(date: todayStr, space: space, workspacePath: workspacePath)
    }

    /// Searches indexed daily notes matching a text query, date, or tags.
    public func searchDailyNotes(
        query: String,
        space: SpaceModel? = nil,
        workspacePath: String? = nil,
        limit: Int = 10
    ) -> [DailyNoteMatch] {
        let entries = indexDailyNotes(space: space, workspacePath: workspacePath)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            return entries.prefix(limit).map { entry in
                DailyNoteMatch(
                    date: entry.date,
                    filePath: entry.filePath,
                    title: entry.title,
                    snippet: String(entry.content.prefix(200)),
                    score: 1.0
                )
            }
        }

        let queryTokens = q
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }

        var matches: [DailyNoteMatch] = []

        for entry in entries {
            let contentLower = entry.content.lowercased()
            let titleLower = entry.title.lowercased()
            let dateLower = entry.date.lowercased()

            var score: Double = 0.0

            // Exact date match is highest priority
            if dateLower == q || dateLower.contains(q) {
                score += 10.0
            }

            // Title match
            if titleLower.contains(q) {
                score += 5.0
            }

            // Tag match
            for tag in entry.tags {
                if tag.lowercased().contains(q) || q.contains(tag.lowercased()) {
                    score += 4.0
                }
            }

            // Content token scoring
            if !queryTokens.isEmpty {
                let hitCount = queryTokens.filter { contentLower.contains($0) }.count
                if hitCount > 0 {
                    score += Double(hitCount) * 2.0
                }
                if contentLower.contains(q) {
                    score += 4.0
                }
            }

            if score > 0 {
                let snippet = Self.extractSnippet(from: entry.content, matching: q, tokens: queryTokens)
                matches.append(DailyNoteMatch(
                    date: entry.date,
                    filePath: entry.filePath,
                    title: entry.title,
                    snippet: snippet,
                    score: score
                ))
            }
        }

        matches.sort { $0.score > $1.score }
        return Array(matches.prefix(limit))
    }

    // MARK: - 5. Composed Memory Tier Instructions

    /// Builds a combined prompt block with all active files-first memory tiers:
    /// MEMORY.md, PERSONA.md, and USER.md.
    public func buildComposedMemoryInstructions(space: SpaceModel? = nil, workspacePath: String? = nil) -> String {
        var blocks: [String] = []

        if let curatedMemory = loadCuratedMemory(for: space, workspacePath: workspacePath), !curatedMemory.isEmpty {
            blocks.append("=== SPACE CURATED MEMORY (MEMORY.md) ===\n\(curatedMemory)")
        }

        if let persona = loadPersona(for: space, workspacePath: workspacePath), !persona.isEmpty {
            blocks.append("=== AGENT PERSONA & BEHAVIOUR (PERSONA.md) ===\n\(persona)")
        }

        if let userContext = loadUserContext(for: space, workspacePath: workspacePath), !userContext.isEmpty {
            blocks.append("=== USER PROFILE & PREFERENCES (USER.md) ===\n\(userContext)")
        }

        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Private Helpers

    public static func normalizeDateString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = extractDate(from: trimmed) {
            return match
        }
        return trimmed
    }

    public static func extractDate(from text: String) -> String? {
        let pattern = #"\b(\d{4}-\d{2}-\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let r = Range(match.range(at: 1), in: text) {
            return String(text[r])
        }
        return nil
    }

    public static func extractTitle(from markdown: String, fallback: String) -> String {
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let clean = trimmed.drop(while: { $0 == "#" || $0 == " " })
                if !clean.isEmpty {
                    return String(clean)
                }
            }
        }
        return fallback
    }

    public static func extractTags(from text: String) -> [String] {
        let pattern = #"#([a-zA-Z0-9_\-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match in
            guard let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    public static func extractSnippet(from content: String, matching query: String, tokens: [String]) -> String {
        let lines = content.components(separatedBy: .newlines)
        for (idx, line) in lines.enumerated() {
            let lower = line.lowercased()
            if lower.contains(query.lowercased()) || tokens.contains(where: { lower.contains($0) }) {
                let start = max(0, idx - 1)
                let end = min(lines.count - 1, idx + 2)
                return lines[start...end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return String(content.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
