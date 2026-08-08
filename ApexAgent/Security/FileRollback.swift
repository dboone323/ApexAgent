import Foundation

/// File-write rollback safety net (WS5.7).
///
/// Before a destructive file operation (overwrite, delete, move), call
/// `snapshot(path:)` to stash the current bytes at `<path>.apex-bak`. If the
/// operation needs to be undone, `rollback(path:)` restores the stashed bytes
/// (or recreates a deleted file). This gives the agent a per-file "undo" for
/// its own writes without a full version-control layer.
///
/// Snapshots are keyed by the canonical path so repeated edits keep the most
/// recent pre-edit state. The `.apex-bak` sidecar is intentionally simple and
/// local — it is not a substitute for git, just a last-resort recovery for a
/// single agent write.
public enum FileRollback {
    /// Snapshot `path`'s current contents (if any) to `<path>.apex-bak`.
    /// Safe to call before any write/delete/move. Returns the snapshot URL on
    /// success, or `nil` if nothing needed snapshotting.
    @discardableResult
    public static func snapshot(path: String) -> URL? {
        let fm = FileManager.default
        let snapshotURL = snapshotURL(for: path)
        let sourceURL = URL(fileURLWithPath: path)

        // Nothing to snapshot for a non-existent file (e.g. creating new).
        guard fm.fileExists(atPath: path) else { return nil }

        do {
            // Remove any stale snapshot first so we don't append/merge.
            if fm.fileExists(atPath: snapshotURL.path) {
                try fm.removeItem(at: snapshotURL)
            }
            try fm.copyItem(at: sourceURL, to: snapshotURL)
            return snapshotURL
        } catch {
            return nil
        }
    }

    /// Restore the most recent snapshot for `path`, if one exists.
    /// Returns `true` if a rollback was performed (file restored or recreated).
    public static func rollback(path: String) -> Bool {
        let fm = FileManager.default
        let snapshotURL = snapshotURL(for: path)
        let targetURL = URL(fileURLWithPath: path)

        guard fm.fileExists(atPath: snapshotURL.path) else { return false }

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

    /// Whether a snapshot exists for `path`.
    public static func hasSnapshot(path: String) -> Bool {
        FileManager.default.fileExists(atPath: snapshotURL(for: path).path)
    }

    /// Discard a snapshot for `path` (e.g. after a successful confirmed op).
    public static func discard(path: String) {
        try? FileManager.default.removeItem(at: snapshotURL(for: path))
    }

    private static func snapshotURL(for path: String) -> URL {
        URL(fileURLWithPath: path + ".apex-bak")
    }
}
