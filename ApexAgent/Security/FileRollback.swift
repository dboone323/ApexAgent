import Foundation
import Synchronization
/// File-write rollback safety net (WS5.7).
///
/// Before a destructive file operation (overwrite, delete, move), call
/// `snapshot(path:)` to stash the current bytes at `<path>.apex-bak` and into
/// the `.apex/snapshots` directory. If the operation needs to be undone,
/// `rollback(path:)` restores the stashed bytes (or recreates a deleted file).
/// `rollbackLast()` undoes the most recent agent file modification.
///
/// Snapshots directory is automatically pruned to keep at most 50 snapshots.
public struct FileRollbackSnapshot: Identifiable, Sendable, Codable {
    public let id: UUID
    public let originalPath: String
    public let snapshotPath: String
    public let timestamp: Date
    public let sizeBytes: Int64

    public var snapshotURL: URL {
        URL(fileURLWithPath: snapshotPath)
    }

    public init(
        id: UUID = UUID(),
        originalPath: String,
        snapshotPath: String,
        timestamp: Date = Date(),
        sizeBytes: Int64 = 0
    ) {
        self.id = id
        self.originalPath = originalPath
        self.snapshotPath = snapshotPath
        self.timestamp = timestamp
        self.sizeBytes = sizeBytes
    }
}

public enum FileRollback {
    private static let maxSnapshotsToKeep = 50
    private static let lock = NSLock()
    private static let recordedSnapshots = Mutex<[FileRollbackSnapshot]>([])

    private static var snapshotsDirectory: URL {
        ApexAgentStoragePaths.directory("snapshots")
    }

    /// Snapshot `path`'s current contents (if any) to `<path>.apex-bak` and to
    /// the central snapshots archive. Safe to call before any write/delete/move.
    /// Returns the primary snapshot URL on success, or `nil` if nothing needed snapshotting.
    @discardableResult
    public static func snapshot(path: String) -> URL? {
        let fm = FileManager.default
        let sidecarURL = snapshotURL(for: path)
        let sourceURL = URL(fileURLWithPath: path)

        // Nothing to snapshot for a non-existent file (e.g. creating new).
        guard fm.fileExists(atPath: path) else { return nil }

        do {
            // Remove any stale sidecar first so we don't append/merge.
            if fm.fileExists(atPath: sidecarURL.path) {
                try fm.removeItem(at: sidecarURL)
            }
            try fm.copyItem(at: sourceURL, to: sidecarURL)

            // Central snapshot directory storage (auto-pruned to 50 items)
            let snapshotsDir = snapshotsDirectory
            try? fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
            
            let filename = sourceURL.lastPathComponent
            let timestampStr = Int(Date().timeIntervalSince1970 * 1000)
            let archiveName = "\(filename).\(timestampStr).bak"
            let archiveURL = snapshotsDir.appendingPathComponent(archiveName)
            
            try? fm.copyItem(at: sourceURL, to: archiveURL)
            let fileSize = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

            let record = FileRollbackSnapshot(
                originalPath: path,
                snapshotPath: archiveURL.path,
                timestamp: Date(),
                sizeBytes: fileSize
            )

            recordedSnapshots.withLock { snapshots in
                snapshots.insert(record, at: 0)
                guard snapshots.count > maxSnapshotsToKeep else { return }
                let excess = snapshots.suffix(from: maxSnapshotsToKeep)
                for item in excess {
                    try? fm.removeItem(atPath: item.snapshotPath)
                }
                snapshots = Array(snapshots.prefix(maxSnapshotsToKeep))
            }

            return sidecarURL
        } catch {
            return nil
        }
    }

    /// Restore the most recent snapshot for `path`, if one exists.
    /// Returns `true` if a rollback was performed (file restored or recreated).
    public static func rollback(path: String) -> Bool {
        let fm = FileManager.default
        let sidecarURL = snapshotURL(for: path)
        let targetURL = URL(fileURLWithPath: path)

        // Check sidecar first, then fallback to most recent archive snapshot
        var sourceSnapshotURL: URL?
        if fm.fileExists(atPath: sidecarURL.path) {
            sourceSnapshotURL = sidecarURL
        } else {
            let match = recordedSnapshots.withLock { $0.first(where: { $0.originalPath == path }) }
            if let match = match, fm.fileExists(atPath: match.snapshotPath) {
                sourceSnapshotURL = match.snapshotURL
            }
        }

        guard let snapshotURL = sourceSnapshotURL, fm.fileExists(atPath: snapshotURL.path) else {
            return false
        }

        do {
            // If the live file exists, replace it; if the op deleted it,
            // recreate it from the snapshot.
            if fm.fileExists(atPath: path) {
                try fm.removeItem(at: targetURL)
            }
            try fm.copyItem(at: snapshotURL, to: targetURL)
            return true
        } catch {
            return false
        }
    }

    /// Reverts the most recently snapshot file across all tools.
    /// Returns the restored path and success flag, or nil if no snapshots exist.
    public static func rollbackLast() -> (path: String, success: Bool)? {
        let mostRecent = recordedSnapshots.withLock { $0.first }

        guard let target = mostRecent else { return nil }
        let success = rollback(path: target.originalPath)
        return (path: target.originalPath, success: success)
    }

    /// List recorded snapshots, most recent first.
    public static func recentSnapshots(limit: Int = 50) -> [FileRollbackSnapshot] {
        return recordedSnapshots.withLock { Array($0.prefix(limit)) }
    }

    /// Whether a snapshot exists for `path`.
    public static func hasSnapshot(path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: snapshotURL(for: path).path) {
            return true
        }
        return recordedSnapshots.withLock { $0.contains(where: { $0.originalPath == path && fm.fileExists(atPath: $0.snapshotPath) }) }
    }

    /// Discard a snapshot for `path` (e.g. after a successful confirmed op).
    public static func discard(path: String) {
        try? FileManager.default.removeItem(at: snapshotURL(for: path))
        recordedSnapshots.withLock { $0.removeAll(where: { $0.originalPath == path }) }
    }

    public static func clearAllSnapshots() {
        recordedSnapshots.withLock { $0.removeAll() }
        try? FileManager.default.removeItem(at: snapshotsDirectory)
    }

    private static func snapshotURL(for path: String) -> URL {
        URL(fileURLWithPath: path + ".apex-bak")
    }

    // prune handled inline above

}

extension FileRollbackSnapshot {
    public func formatAsMarkdown() -> String {
        var md = "### 🗂️ Rollback Snapshot `\(originalPath)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Original | `\(originalPath)` |\n"
        md += "| Snapshot | `\(snapshotPath)` |\n"
        md += "| Taken | `\(timestamp)` |\n"
        md += "| Size | `\(sizeBytes)` bytes |\n"
        return md
    }

    public var isNonEmpty: Bool { sizeBytes > 0 }
}
