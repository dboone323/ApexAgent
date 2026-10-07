import Foundation

/// Metadata describing a corrupt JSON file recovery performed by ``ResilientJSONStore``.
public struct PersistenceRecoveryEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let subsystem: String
    public let originalPath: String
    public let backupPath: String
    public let byteCount: Int
    public let errorDescription: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        subsystem: String,
        originalPath: String,
        backupPath: String,
        byteCount: Int,
        errorDescription: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.subsystem = subsystem
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.byteCount = byteCount
        self.errorDescription = errorDescription
    }
}

/// Resilient JSON persistence helper that normalizes atomic writes and recovers from
/// truncated, invalid, or schema-mismatched JSON files by moving the corrupt file aside
/// to `<filename>.corrupt-<timestamp>` (preserving the original bytes intact), emitting a
/// structured recovery event to ``AppLog`` and diagnostics, and returning the caller's
/// default fallback value.
public final class ResilientJSONStore: @unchecked Sendable {
    public static let shared = ResilientJSONStore()

    private let lock = NSLock()
    private var events: [PersistenceRecoveryEvent] = []
    private let maxEvents: Int

    public init(maxEvents: Int = 200) {
        self.maxEvents = max(1, maxEvents)
    }

    /// Returns recent corruption recovery events in chronological order.
    public func recentRecoveryEvents(limit: Int = 50) -> [PersistenceRecoveryEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard limit > 0 else { return [] }
        return Array(events.suffix(limit))
    }

    public var recoveryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    public func clearRecoveryEvents() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll()
    }

    /// Atomically encodes and writes `value` to `url`, creating intermediate directories if needed.
    public func save<T: Encodable>(_ value: T, to url: URL, prettyPrinted: Bool = false) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    /// Loads and decodes `T` from `url`. If the file does not exist, returns `defaultValue()`.
    /// If the file exists but fails to decode (truncated, invalid syntax, or schema mismatch),
    /// moves the corrupt file aside to `<filename>.corrupt-<ts>` (byte-preserving), records a
    /// ``PersistenceRecoveryEvent``, logs via ``AppLog``, and returns `defaultValue()`.
    public func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        subsystem: String = "persistence",
        default defaultValue: @autoclosure () -> T,
        now: () -> Date = Date.init
    ) -> T {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return defaultValue()
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            _ = quarantineCorruptData(
                data,
                at: url,
                subsystem: subsystem,
                errorDescription: String(describing: error),
                now: now()
            )
            return defaultValue()
        }
    }

    /// Loads an untyped JSON object via `JSONSerialization`. On corrupt JSON syntax, moves the
    /// file aside to `<filename>.corrupt-<ts>`, records a recovery event, and returns `nil`.
    public func loadJSONObject(
        from url: URL,
        subsystem: String = "persistence",
        now: () -> Date = Date.init
    ) -> Any? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            _ = quarantineCorruptData(
                data,
                at: url,
                subsystem: subsystem,
                errorDescription: String(describing: error),
                now: now()
            )
            return nil
        }
    }

    /// Moves a file whose structure failed domain validation aside to `<filename>.corrupt-<ts>`,
    /// preserving its exact bytes, and records a ``PersistenceRecoveryEvent``.
    @discardableResult
    public func quarantineCorruptFile(
        at url: URL,
        subsystem: String,
        errorDescription: String,
        now: Date = Date()
    ) -> PersistenceRecoveryEvent? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return quarantineCorruptData(
            data,
            at: url,
            subsystem: subsystem,
            errorDescription: errorDescription,
            now: now
        )
    }

    @discardableResult
    private func quarantineCorruptData(
        _ data: Data,
        at url: URL,
        subsystem: String,
        errorDescription: String,
        now: Date
    ) -> PersistenceRecoveryEvent {
        let timestampMs = Int64((now.timeIntervalSince1970 * 1000.0).rounded())
        var backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestampMs)")
        var suffix = 1
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).corrupt-\(timestampMs)-\(suffix)")
            suffix += 1
        }

        // Write exact bytes atomically to the backup path and remove the corrupt original.
        try? data.write(to: backupURL, options: .atomic)
        try? FileManager.default.removeItem(at: url)

        let event = PersistenceRecoveryEvent(
            timestamp: now,
            subsystem: subsystem,
            originalPath: url.path,
            backupPath: backupURL.path,
            byteCount: data.count,
            errorDescription: errorDescription
        )

        lock.lock()
        if events.count >= maxEvents {
            events.removeFirst(events.count - maxEvents + 1)
        }
        events.append(event)
        lock.unlock()

        AppLog.error(
            .app,
            "Recovered from corrupt JSON in \(subsystem) (\(url.lastPathComponent), \(data.count) bytes) -> \(backupURL.lastPathComponent)"
        )
        TraceBus.shared.append(
            TraceEvent(
                source: "ResilientJSONStore",
                operation: "persistence.corruption_recovery",
                detail: "\(subsystem): \(url.lastPathComponent) -> \(backupURL.lastPathComponent)",
                metadata: [
                    "subsystem": subsystem,
                    "original_path": url.path,
                    "backup_path": backupURL.path,
                    "bytes": "\(data.count)"
                ]
            )
        )
        return event
    }
}
