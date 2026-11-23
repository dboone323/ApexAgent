import Foundation
import SharedKit

// MARK: - Shared Memory Block (Issue #84 / B6)

/// A named block of memory shared across all agents in a Space.
/// Every agent in the same Space reads and writes to this block, enabling shared state
/// without requiring each agent to maintain redundant private copies.
public struct SharedMemoryBlock: Identifiable, Sendable, Codable, Equatable {
    public var id: String // Named block identifier (e.g. "architecture_spec", "incident_triage")
    public let spaceId: String // ID of the Space scoping this block
    public var content: String // The current payload/content of the memory block
    public var version: Int // Monotonically increasing revision counter (1, 2, 3...)
    public var writerId: String // Identifier of the agent who committed this revision
    public var timestamp: Date // Exact time of last write
    public var metadata: [String: String] // Key-value annotations (e.g., tags, schema version)

    public init(
        id: String,
        spaceId: String,
        content: String,
        version: Int = 1,
        writerId: String,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.spaceId = spaceId
        self.content = content
        self.version = version
        self.writerId = writerId
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

// MARK: - Shared Memory Conflict Record

/// An immutable conflict record produced whenever concurrent or stale writes collide.
/// Guarantees that no write silently overwrites another without a trace:
/// the losing writer's payload is fully preserved and inspectable.
public struct SharedMemoryConflict: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let blockId: String
    public let spaceId: String
    public let baseVersion: Int // Version the conflicting writer targeted / assumed
    public let currentVersion: Int // Version that won or was active when conflict occurred
    public let winningWriterId: String // Agent identifier of the accepted revision
    public let winningContent: String // Content of the accepted revision
    public let conflictingWriterId: String // Agent identifier whose write was rejected / conflicted
    public let conflictingContent: String // Losing content, preserved for recovery and audit
    public let timestamp: Date
    public let reason: String

    public init(
        id: UUID = UUID(),
        blockId: String,
        spaceId: String,
        baseVersion: Int,
        currentVersion: Int,
        winningWriterId: String,
        winningContent: String,
        conflictingWriterId: String,
        conflictingContent: String,
        timestamp: Date = Date(),
        reason: String = "Optimistic concurrency conflict"
    ) {
        self.id = id
        self.blockId = blockId
        self.spaceId = spaceId
        self.baseVersion = baseVersion
        self.currentVersion = currentVersion
        self.winningWriterId = winningWriterId
        self.winningContent = winningContent
        self.conflictingWriterId = conflictingWriterId
        self.conflictingContent = conflictingContent
        self.timestamp = timestamp
        self.reason = reason
    }
}

// MARK: - Shared Memory Write Result

/// Result of attempting to write to a shared memory block.
public enum SharedMemoryWriteResult: Sendable, Equatable {
    case success(SharedMemoryBlock)
    case conflict(conflict: SharedMemoryConflict, currentBlock: SharedMemoryBlock)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    public var isConflict: Bool {
        if case .conflict = self { return true }
        return false
    }

    public var block: SharedMemoryBlock {
        switch self {
        case .success(let b): return b
        case .conflict(_, let b): return b
        }
    }

    public var conflictRecord: SharedMemoryConflict? {
        switch self {
        case .success: return nil
        case .conflict(let c, _): return c
        }
    }
}

// MARK: - SharedMemoryBlockService

/// Coordinates shared memory blocks across multiple collaborating agents in a Space.
/// Features:
/// 1. Space-scoped block reading and writing.
/// 2. Optimistic concurrency control (OCC) via expectedVersion.
/// 3. Zero-loss conflict handling preserving losing writer data in conflict audit logs.
/// 4. Disk persistence and recovery across app restarts.
@MainActor
public final class SharedMemoryBlockService {
    public static let shared = SharedMemoryBlockService()

    private let customStorageDirectory: URL?

    // Cache: spaceId -> [blockId: SharedMemoryBlock]
    private var blocksCache: [String: [String: SharedMemoryBlock]] = [:]

    // Cache: spaceId -> [SharedMemoryConflict]
    private var conflictsCache: [String: [SharedMemoryConflict]] = [:]

    // Tracks whether disk state has been loaded for a space
    private var loadedSpaces: Set<String> = []

    public init(storageDirectory: URL? = nil) {
        self.customStorageDirectory = storageDirectory
    }

    // MARK: - Storage Path Resolution

    /// Resolves the storage root for shared memory blocks in a given Space.
    public func resolveStorageURL(spaceId: String, workspacePath: String? = nil) -> URL {
        if let custom = customStorageDirectory {
            return custom.appendingPathComponent(spaceId, isDirectory: true)
        }
        if let ws = workspacePath, !ws.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = (ws as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
                .appendingPathComponent(".apex", isDirectory: true)
                .appendingPathComponent("shared_memory", isDirectory: true)
                .appendingPathComponent(spaceId, isDirectory: true)
        }
        return ApexAgentStoragePaths.directory("spaces/\(spaceId)/shared_memory")
    }

    public func blocksDirectory(spaceId: String, workspacePath: String? = nil) -> URL {
        resolveStorageURL(spaceId: spaceId, workspacePath: workspacePath).appendingPathComponent("blocks", isDirectory: true)
    }

    public func conflictsDirectory(spaceId: String, workspacePath: String? = nil) -> URL {
        resolveStorageURL(spaceId: spaceId, workspacePath: workspacePath).appendingPathComponent("conflicts", isDirectory: true)
    }

    public func blockFilePath(spaceId: String, blockId: String, workspacePath: String? = nil) -> String {
        let sanitized = sanitizeIdentifier(blockId)
        return blocksDirectory(spaceId: spaceId, workspacePath: workspacePath).appendingPathComponent("\(sanitized).json").path
    }

    private func sanitizeIdentifier(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: "..", with: "_")
    }

    // MARK: - Disk Persistence

    private func ensureLoaded(spaceId: String, workspacePath: String? = nil) {
        guard !loadedSpaces.contains(spaceId) else { return }
        loadedSpaces.insert(spaceId)

        let blocksDir = blocksDirectory(spaceId: spaceId, workspacePath: workspacePath)
        let fm = FileManager.default

        var loadedBlocks: [String: SharedMemoryBlock] = [:]
        if let files = try? fm.contentsOfDirectory(at: blocksDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let block = try? decoder.decode(SharedMemoryBlock.self, from: data) {
                    loadedBlocks[block.id] = block
                }
            }
        }
        blocksCache[spaceId] = loadedBlocks

        let conflictsDir = conflictsDirectory(spaceId: spaceId, workspacePath: workspacePath)
        var loadedConflicts: [SharedMemoryConflict] = []
        if let files = try? fm.contentsOfDirectory(at: conflictsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let conflict = try? decoder.decode(SharedMemoryConflict.self, from: data) {
                    loadedConflicts.append(conflict)
                }
            }
        }
        loadedConflicts.sort(by: { $0.timestamp < $1.timestamp })
        conflictsCache[spaceId] = loadedConflicts
    }

    private func persistBlockToDisk(_ block: SharedMemoryBlock, workspacePath: String? = nil) {
        let path = blockFilePath(spaceId: block.spaceId, blockId: block.id, workspacePath: workspacePath)
        let fileURL = URL(fileURLWithPath: path)
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(block) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func persistConflictToDisk(_ conflict: SharedMemoryConflict, workspacePath: String? = nil) {
        let conflictsDir = conflictsDirectory(spaceId: conflict.spaceId, workspacePath: workspacePath)
        let fileURL = conflictsDir.appendingPathComponent("\(conflict.id.uuidString).json")
        let fm = FileManager.default
        try? fm.createDirectory(at: conflictsDir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(conflict) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Core Operations

    /// Reads a shared memory block scoped to a specific Space.
    /// Returns nil if the block does not exist or has not been initialized.
    public func readBlock(spaceId: String, blockId: String, workspacePath: String? = nil) -> SharedMemoryBlock? {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)
        return blocksCache[spaceId]?[blockId]
    }

    /// Writes content to a named shared memory block scoped to a Space.
    ///
    /// - Parameters:
    ///   - spaceId: The identifier of the Space.
    ///   - blockId: The identifier of the block (e.g., "roadmap", "architecture").
    ///   - content: The new content payload.
    ///   - writerId: The agent identifier performing the write.
    ///   - expectedVersion: Optional expected version for optimistic concurrency control.
    ///     If provided and different from the current block version, a conflict record is generated
    ///     and the losing write's content is preserved without data loss.
    ///   - workspacePath: Optional workspace root directory.
    ///   - metadata: Optional key-value annotations.
    /// - Returns: A SharedMemoryWriteResult indicating success or conflict.
    public func writeBlock(
        spaceId: String,
        blockId: String,
        content: String,
        writerId: String,
        expectedVersion: Int? = nil,
        workspacePath: String? = nil,
        metadata: [String: String] = [:]
    ) -> SharedMemoryWriteResult {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)

        var spaceBlocks = blocksCache[spaceId] ?? [:]

        if let existing = spaceBlocks[blockId] {
            // Check for optimistic concurrency conflict
            if let expected = expectedVersion, expected != existing.version {
                let conflict = SharedMemoryConflict(
                    blockId: blockId,
                    spaceId: spaceId,
                    baseVersion: expected,
                    currentVersion: existing.version,
                    winningWriterId: existing.writerId,
                    winningContent: existing.content,
                    conflictingWriterId: writerId,
                    conflictingContent: content,
                    timestamp: Date(),
                    reason: "Optimistic concurrency collision: agent '\(writerId)' targeted version \(expected), but block was updated to version \(existing.version) by '\(existing.writerId)'."
                )

                var spaceConflicts = conflictsCache[spaceId] ?? []
                spaceConflicts.append(conflict)
                conflictsCache[spaceId] = spaceConflicts

                persistConflictToDisk(conflict, workspacePath: workspacePath)

                AppLog.warning(.app, "Shared memory block conflict: \(conflict.reason)")
                return .conflict(conflict: conflict, currentBlock: existing)
            }

            // Normal sequential write or expectedVersion matches
            let updated = SharedMemoryBlock(
                id: blockId,
                spaceId: spaceId,
                content: content,
                version: existing.version + 1,
                writerId: writerId,
                timestamp: Date(),
                metadata: metadata.isEmpty ? existing.metadata : metadata
            )

            spaceBlocks[blockId] = updated
            blocksCache[spaceId] = spaceBlocks
            persistBlockToDisk(updated, workspacePath: workspacePath)

            return .success(updated)
        } else {
            // First write initializes version 1
            if let expected = expectedVersion, expected > 0 {
                // Expected an existing version, but block is missing
                let conflict = SharedMemoryConflict(
                    blockId: blockId,
                    spaceId: spaceId,
                    baseVersion: expected,
                    currentVersion: 0,
                    winningWriterId: "none",
                    winningContent: "",
                    conflictingWriterId: writerId,
                    conflictingContent: content,
                    timestamp: Date(),
                    reason: "Block '\(blockId)' does not exist (targeted version \(expected))."
                )
                var spaceConflicts = conflictsCache[spaceId] ?? []
                spaceConflicts.append(conflict)
                conflictsCache[spaceId] = spaceConflicts
                persistConflictToDisk(conflict, workspacePath: workspacePath)

                let emptyBlock = SharedMemoryBlock(id: blockId, spaceId: spaceId, content: "", version: 0, writerId: "none")
                return .conflict(conflict: conflict, currentBlock: emptyBlock)
            }

            let newBlock = SharedMemoryBlock(
                id: blockId,
                spaceId: spaceId,
                content: content,
                version: 1,
                writerId: writerId,
                timestamp: Date(),
                metadata: metadata
            )

            spaceBlocks[blockId] = newBlock
            blocksCache[spaceId] = spaceBlocks
            persistBlockToDisk(newBlock, workspacePath: workspacePath)

            return .success(newBlock)
        }
    }

    /// Lists all shared memory blocks currently registered for a Space.
    public func listBlocks(spaceId: String, workspacePath: String? = nil) -> [SharedMemoryBlock] {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)
        let spaceBlocks = blocksCache[spaceId] ?? [:]
        return Array(spaceBlocks.values).sorted(by: { $0.id < $1.id })
    }

    /// Retrieves all recorded conflicts for a Space, optionally filtered by block ID.
    public func getConflicts(spaceId: String, blockId: String? = nil, workspacePath: String? = nil) -> [SharedMemoryConflict] {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)
        let conflicts = conflictsCache[spaceId] ?? []
        if let bId = blockId {
            return conflicts.filter { $0.blockId == bId }
        }
        return conflicts
    }

    /// Resolves an existing conflict by deliberately applying a chosen resolution payload.
    /// The conflict record remains in the conflict log for full auditing.
    public func resolveConflict(
        conflictId: UUID,
        spaceId: String,
        chosenContent: String,
        resolverId: String,
        workspacePath: String? = nil
    ) -> SharedMemoryBlock? {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)
        guard let conflict = (conflictsCache[spaceId] ?? []).first(where: { $0.id == conflictId }) else {
            return nil
        }

        let writeRes = writeBlock(
            spaceId: spaceId,
            blockId: conflict.blockId,
            content: chosenContent,
            writerId: resolverId,
            expectedVersion: nil, // force resolution update
            workspacePath: workspacePath,
            metadata: ["resolvedConflictId": conflictId.uuidString, "resolver": resolverId]
        )

        return writeRes.block
    }

    /// Deletes a shared memory block from memory and disk.
    public func deleteBlock(spaceId: String, blockId: String, writerId: String, workspacePath: String? = nil) -> Bool {
        ensureLoaded(spaceId: spaceId, workspacePath: workspacePath)
        guard var spaceBlocks = blocksCache[spaceId], spaceBlocks[blockId] != nil else {
            return false
        }
        spaceBlocks.removeValue(forKey: blockId)
        blocksCache[spaceId] = spaceBlocks

        let path = blockFilePath(spaceId: spaceId, blockId: blockId, workspacePath: workspacePath)
        try? FileManager.default.removeItem(atPath: path)
        return true
    }

    /// Resets in-memory caches (for testing and lifecycle verification).
    public func clearCache() {
        blocksCache.removeAll()
        conflictsCache.removeAll()
        loadedSpaces.removeAll()
    }
}
