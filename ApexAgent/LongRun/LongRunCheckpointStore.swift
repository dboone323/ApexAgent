import Foundation
import Darwin

// MARK: - Durable Long Run Checkpoint Store (Issue #77)

/// Actor responsible for persisting, indexing, and recovering long run checkpoints.
public actor LongRunCheckpointStore {
    public static let shared = LongRunCheckpointStore()

    public let baseDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else if let env = ProcessInfo.processInfo.environment["APEX_LONG_RUNS_DIR"], !env.isEmpty {
            self.baseDirectory = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            self.baseDirectory = ApexAgentStoragePaths.directory("long_runs")
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    /// Directory for a specific run.
    public func runDirectory(for runId: UUID) -> URL {
        baseDirectory.appendingPathComponent(runId.uuidString, isDirectory: true)
    }

    /// Path to the latest checkpoint for a run.
    public func latestCheckpointURL(for runId: UUID) -> URL {
        runDirectory(for: runId).appendingPathComponent("checkpoint.json")
    }

    /// Path to the immutable spec for a run.
    public func specURL(for runId: UUID) -> URL {
        runDirectory(for: runId).appendingPathComponent("spec.json")
    }

    /// Path to historical sequenced checkpoints.
    public func historyDirectory(for runId: UUID) -> URL {
        runDirectory(for: runId).appendingPathComponent("checkpoints", isDirectory: true)
    }

    /// Persists a checkpoint atomically to disk.
    public func save(checkpoint: LongRunCheckpoint) throws {
        let runDir = runDirectory(for: checkpoint.runId)
        let histDir = historyDirectory(for: checkpoint.runId)
        let fm = FileManager.default

        if !fm.fileExists(atPath: histDir.path) {
            try fm.createDirectory(at: histDir, withIntermediateDirectories: true)
        }

        // 1. Ensure spec is written
        let specFile = specURL(for: checkpoint.runId)
        if !fm.fileExists(atPath: specFile.path) {
            let specData = try encoder.encode(checkpoint.spec)
            try specData.write(to: specFile, options: .atomic)
        }

        // 2. Encode checkpoint
        let data = try encoder.encode(checkpoint)

        // 3. Save latest checkpoint atomically
        let latestFile = latestCheckpointURL(for: checkpoint.runId)
        try data.write(to: latestFile, options: .atomic)

        // 4. Save sequenced historical snapshot
        let seqFile = histDir.appendingPathComponent(String(format: "%06d.json", checkpoint.sequenceNumber))
        try data.write(to: seqFile, options: .atomic)

        // 5. If terminal, write Markdown receipt
        if checkpoint.status.isTerminal {
            let receiptFile = runDir.appendingPathComponent("receipt.md")
            let md = checkpoint.formatMarkdownReceipt()
            try? md.write(to: receiptFile, atomically: true, encoding: .utf8)
        }
    }

    /// Loads the latest checkpoint for a run, if present.
    public func loadLatestCheckpoint(runId: UUID) -> LongRunCheckpoint? {
        let file = latestCheckpointURL(for: runId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(LongRunCheckpoint.self, from: data)
        } catch {
            return nil
        }
    }

    /// Loads a specific sequence checkpoint.
    public func loadCheckpointSequence(runId: UUID, sequence: Int) -> LongRunCheckpoint? {
        let histDir = historyDirectory(for: runId)
        let file = histDir.appendingPathComponent(String(format: "%06d.json", sequence))
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try decoder.decode(LongRunCheckpoint.self, from: data)
        } catch {
            return nil
        }
    }

    /// Lists all known runs sorted by savedAt descending.
    public func listAllRuns() -> [LongRunCheckpoint] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil) else {
            return []
        }

        var results: [LongRunCheckpoint] = []
        for dir in subdirs {
            guard let uuid = UUID(uuidString: dir.lastPathComponent) else { continue }
            if let ckpt = loadLatestCheckpoint(runId: uuid) {
                results.append(ckpt)
            }
        }

        return results.sorted { $0.savedAt > $1.savedAt }
    }

    /// Discovers runs that were left in `.running` state when process crashed or machine slept.
    public func findInterruptedRuns() -> [LongRunCheckpoint] {
        let all = listAllRuns()
        return all.filter { ckpt in
            guard ckpt.status == .running else { return false }
            // Verify if process ID is still alive
            let isAlive = isProcessAlive(pid: ckpt.processId)
            return !isAlive
        }
    }

    /// Deletes all files associated with a run.
    public func deleteRun(runId: UUID) throws {
        let dir = runDirectory(for: runId)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Cleans all runs in the store (primarily for test teardown).
    public func cleanAll() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: baseDirectory.path) {
            try fm.removeItem(at: baseDirectory)
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    /// Internal POSIX check to see if PID is actively running.
    private func isProcessAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == ProcessInfo.processInfo.processIdentifier {
            return true
        }
        let res = Darwin.kill(pid, 0)
        if res == 0 {
            return true
        }
        return Darwin.errno != ESRCH
    }
}
