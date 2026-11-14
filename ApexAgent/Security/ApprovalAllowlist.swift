import Foundation

// MARK: - Allowlist Entry (Issue #105)

/// A persisted entry recording that Daniel approved an exact command
/// in a specific directory, with an explicit expiration date.
public struct AllowlistEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let command: String
    public let directory: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        command: String,
        directory: String,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.command = command
        self.directory = directory
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    /// Whether this entry has expired relative to the given reference date.
    public func isExpired(now: Date = Date()) -> Bool {
        now >= expiresAt
    }
}

// MARK: - Approval Allowlist (Issue #105)

/// Thread-safe, UserDefaults-backed allowlist manager for command + directory pairs.
///
/// Features:
/// - Exact command + directory matching
/// - Default named expiry: `defaultApprovalTTL` (24 hours / 86,400s)
/// - Safe revocation: list entries and remove by ID or command + directory
/// - Thread-safe synchronization via NSLock
public final class ApprovalAllowlist: @unchecked Sendable {
    public static let shared = ApprovalAllowlist()

    /// Default time-to-live for an approved command in a directory: 24 hours (86,400 seconds).
    public static let defaultApprovalTTL: TimeInterval = 86_400

    private static let userDefaultsKey = "apex.commandDirectoryAllowlist"

    private let lock = NSLock()
    private var entries: [AllowlistEntry]

    public init(userDefaults: UserDefaults = .standard) {
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode([AllowlistEntry].self, from: data) {
            self.entries = decoded
        } else {
            self.entries = []
        }
    }

    /// Standardize directory path for consistent comparison.
    public static func standardizeDirectory(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardized
        var cleanPath = url.path
        if cleanPath.count > 1 && cleanPath.hasSuffix("/") {
            cleanPath.removeLast()
        }
        return cleanPath
    }

    /// Records an approved command in a directory with an explicit expiry TTL.
    @discardableResult
    public func allow(
        command: String,
        directory: String,
        ttl: TimeInterval = defaultApprovalTTL,
        now: Date = Date()
    ) -> AllowlistEntry {
        lock.lock()
        defer { lock.unlock() }

        let cleanDir = Self.standardizeDirectory(directory)
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresAt = now.addingTimeInterval(ttl)

        // Replace any existing entry for this exact command and directory
        entries.removeAll {
            $0.command == trimmedCmd && Self.standardizeDirectory($0.directory) == cleanDir
        }

        let entry = AllowlistEntry(
            command: trimmedCmd,
            directory: cleanDir,
            createdAt: now,
            expiresAt: expiresAt
        )
        entries.append(entry)
        persistLocked()
        return entry
    }

    /// Checks if a command in a directory is currently allowed (must match exactly and not be expired).
    public func isAllowed(
        command: String,
        directory: String,
        now: Date = Date()
    ) -> Bool {
        matchingEntry(command: command, directory: directory, now: now) != nil
    }

    /// Finds a matching non-expired allowlist entry.
    public func matchingEntry(
        command: String,
        directory: String,
        now: Date = Date()
    ) -> AllowlistEntry? {
        lock.lock()
        defer { lock.unlock() }

        let cleanDir = Self.standardizeDirectory(directory)
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)

        return entries.first {
            $0.command == trimmedCmd
                && Self.standardizeDirectory($0.directory) == cleanDir
                && !$0.isExpired(now: now)
        }
    }

    /// Returns a snapshot of all entries (including expired ones, until pruned).
    public func listEntries() -> [AllowlistEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Returns only active, non-expired entries.
    public func activeEntries(now: Date = Date()) -> [AllowlistEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { !$0.isExpired(now: now) }
    }

    /// Revoke an entry by its ID.
    @discardableResult
    public func remove(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let initialCount = entries.count
        entries.removeAll { $0.id == id }
        let changed = entries.count != initialCount
        if changed { persistLocked() }
        return changed
    }

    /// Revoke an entry by exact command and directory.
    @discardableResult
    public func remove(command: String, directory: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let cleanDir = Self.standardizeDirectory(directory)
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialCount = entries.count
        entries.removeAll {
            $0.command == trimmedCmd && Self.standardizeDirectory($0.directory) == cleanDir
        }
        let changed = entries.count != initialCount
        if changed { persistLocked() }
        return changed
    }

    /// Clear all allowlist entries.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        persistLocked()
    }

    /// Prune any entries that have passed their expiration timestamp.
    public func pruneExpired(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        let initialCount = entries.count
        entries.removeAll { $0.isExpired(now: now) }
        if entries.count != initialCount {
            persistLocked()
        }
    }

    private func persistLocked() {
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: Self.userDefaultsKey)
        }
    }
}
