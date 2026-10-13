//
//  DotSandboxSnapshotEngine.swift
//  ApexAgent
//
//  Batch 122: Hardens Dot sandboxes with disk quota budgets, symlink escape
//  detection, environment variable stripping, and snapshot/rollback.
//

import Foundation

// MARK: - Dot Sandbox Error

public enum DotSandboxError: Error, LocalizedError, Sendable, Equatable {
    case quotaExceeded(usedBytes: Int64, limitBytes: Int64)
    case symlinkEscapeAttempt(path: String)
    case snapshotNotFound(id: UUID)
    case snapshotDirectoryCreationFailed(path: String)

    public var errorDescription: String? {
        switch self {
        case .quotaExceeded(let usedBytes, let limitBytes):
            return "Dot sandbox quota exceeded: using \(usedBytes) bytes of \(limitBytes) byte limit."
        case .symlinkEscapeAttempt(let path):
            return "Security violation: symlink path '\(path)' attempts to escape the Dot sandbox jail."
        case .snapshotNotFound(let id):
            return "Dot workspace snapshot '\(id.uuidString)' not found."
        case .snapshotDirectoryCreationFailed(let path):
            return "Failed to create snapshot directory at path '\(path)'."
        }
    }
}

// MARK: - Dot Workspace Snapshot

public struct DotWorkspaceSnapshot: Sendable, Codable, Equatable {
    public let snapshotId: UUID
    public let dotId: UUID
    public let createdAt: Date
    public let snapshotURL: URL
    public let filePaths: [String]

    public init(
        snapshotId: UUID = UUID(),
        dotId: UUID,
        createdAt: Date = Date(),
        snapshotURL: URL,
        filePaths: [String]
    ) {
        self.snapshotId = snapshotId
        self.dotId = dotId
        self.createdAt = createdAt
        self.snapshotURL = snapshotURL
        self.filePaths = filePaths
    }
}

// MARK: - Dot Sandbox Snapshot Engine

public actor DotSandboxSnapshotEngine {
    public static let shared = DotSandboxSnapshotEngine()

    /// Default disk quota: 250 MB (262,144,000 bytes)
    public static let defaultQuotaBytes: Int64 = 262_144_000

    public static let sensitiveEnvironmentPrefixes: [String] = [
        "AWS_", "GITHUB_", "GITLAB_", "SSH_", "GPG_",
        "OPENAI_", "ANTHROPIC_", "GEMINI_", "COPILOT_",
        "SECRET_", "TOKEN_", "KEY_", "PASSWORD_", "CREDENTIAL_"
    ]

    public init() {}

    // MARK: - Disk Quota Enforcement

    /// Recursively calculates total disk usage in bytes for a given Dot sandbox.
    public func currentDiskUsageBytes(for dotId: UUID) throws -> Int64 {
        let root = DotSandboxManager.shared.sandboxURL(for: dotId)
        return try currentDiskUsageBytes(at: root)
    }

    /// Recursively calculates total disk usage in bytes for any directory.
    public func currentDiskUsageBytes(at directoryURL: URL) throws -> Int64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directoryURL.path) else { return 0 }

        let subpaths = (try? fm.subpathsOfDirectory(atPath: directoryURL.path)) ?? []
        var totalBytes: Int64 = 0

        for subpath in subpaths {
            let fullPath = directoryURL.appendingPathComponent(subpath).path
            if let attrs = try? fm.attributesOfItem(atPath: fullPath) {
                let fileType = attrs[.type] as? FileAttributeType
                if fileType != .typeDirectory {
                    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                    totalBytes += size
                }
            }
        }

        return totalBytes
    }

    /// Asserts that a Dot's current sandbox disk usage does not exceed the allotted quota.
    public func assertQuotaNotExceeded(
        for dotId: UUID,
        quotaBytes: Int64 = DotSandboxSnapshotEngine.defaultQuotaBytes
    ) throws {
        let usedBytes = try currentDiskUsageBytes(for: dotId)
        if usedBytes > quotaBytes {
            throw DotSandboxError.quotaExceeded(usedBytes: usedBytes, limitBytes: quotaBytes)
        }
    }

    /// Asserts that a directory's current disk usage does not exceed the allotted quota.
    public func assertQuotaNotExceeded(
        at directoryURL: URL,
        quotaBytes: Int64 = DotSandboxSnapshotEngine.defaultQuotaBytes
    ) throws {
        let usedBytes = try currentDiskUsageBytes(at: directoryURL)
        if usedBytes > quotaBytes {
            throw DotSandboxError.quotaExceeded(usedBytes: usedBytes, limitBytes: quotaBytes)
        }
    }

    // MARK: - Symlink Jail

    /// Resolves path and ensures it stays strictly within the sandbox jail root.
    public static func resolveJailedPath(sandboxRoot: URL, relativePath: String) throws -> URL {
        let resolvedRoot = sandboxRoot.standardizedFileURL.resolvingSymlinksInPath()

        let candidateURL: URL
        if relativePath.hasPrefix("/") {
            if relativePath.hasPrefix(sandboxRoot.path) || relativePath.hasPrefix(resolvedRoot.path) {
                candidateURL = URL(fileURLWithPath: relativePath)
            } else {
                throw DotSandboxError.symlinkEscapeAttempt(path: relativePath)
            }
        } else {
            candidateURL = sandboxRoot.appendingPathComponent(relativePath)
        }

        let resolvedPath = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        let targetPath = resolvedPath.path

        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath == rootPath || targetPath.hasPrefix(rootPrefix) else {
            throw DotSandboxError.symlinkEscapeAttempt(path: relativePath)
        }

        return resolvedPath
    }

    public func resolveJailedPath(sandboxRoot: URL, relativePath: String) throws -> URL {
        try Self.resolveJailedPath(sandboxRoot: sandboxRoot, relativePath: relativePath)
    }

    // MARK: - Environment Sanitization

    /// Strips sensitive credentials and tokens from process environment variables.
    public static func sanitizeEnvironment(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            let upperKey = key.uppercased()
            return !sensitiveEnvironmentPrefixes.contains(where: { upperKey.hasPrefix($0) })
        }
    }

    public func sanitizeEnvironment(_ env: [String: String]) -> [String: String] {
        Self.sanitizeEnvironment(env)
    }

    // MARK: - Workspace Snapshot & Rollback

    /// Creates a complete snapshot of the Dot's `workspace/` directory in `scratch/.snapshots/{snapshotId}/`.
    public func createSnapshot(for dotId: UUID) throws -> DotWorkspaceSnapshot {
        let sandboxRoot = try DotSandboxManager.shared.ensureSandbox(for: dotId)
        let workspaceURL = sandboxRoot.appendingPathComponent("workspace", isDirectory: true)
        let scratchURL = sandboxRoot.appendingPathComponent("scratch", isDirectory: true)
        let snapshotsBase = scratchURL.appendingPathComponent(".snapshots", isDirectory: true)

        let fm = FileManager.default
        if !fm.fileExists(atPath: snapshotsBase.path) {
            do {
                try fm.createDirectory(at: snapshotsBase, withIntermediateDirectories: true)
            } catch {
                throw DotSandboxError.snapshotDirectoryCreationFailed(path: snapshotsBase.path)
            }
        }

        let snapshotId = UUID()
        let snapshotURL = snapshotsBase.appendingPathComponent(snapshotId.uuidString, isDirectory: true)

        let subpaths = (try? fm.subpathsOfDirectory(atPath: workspaceURL.path)) ?? []
        let filePaths = subpaths.sorted()

        do {
            try fm.copyItem(at: workspaceURL, to: snapshotURL)
        } catch {
            throw DotSandboxError.snapshotDirectoryCreationFailed(path: snapshotURL.path)
        }

        let snapshot = DotWorkspaceSnapshot(
            snapshotId: snapshotId,
            dotId: dotId,
            createdAt: Date(),
            snapshotURL: snapshotURL,
            filePaths: filePaths
        )

        let metaURL = snapshotsBase.appendingPathComponent("\(snapshotId.uuidString).meta.json")
        if let metaData = try? JSONEncoder().encode(snapshot) {
            try? metaData.write(to: metaURL, options: .atomic)
        }

        return snapshot
    }

    /// Restores a workspace snapshot, replacing current `workspace/` contents.
    public func restoreSnapshot(_ snapshot: DotWorkspaceSnapshot) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshot.snapshotURL.path) else {
            throw DotSandboxError.snapshotNotFound(id: snapshot.snapshotId)
        }

        let sandboxRoot = DotSandboxManager.shared.sandboxURL(for: snapshot.dotId)
        let workspaceURL = sandboxRoot.appendingPathComponent("workspace", isDirectory: true)

        if fm.fileExists(atPath: workspaceURL.path) {
            try fm.removeItem(at: workspaceURL)
        }

        try fm.copyItem(at: snapshot.snapshotURL, to: workspaceURL)
    }

    /// Lists all snapshots for a Dot in reverse chronological order (newest first).
    public func listSnapshots(for dotId: UUID) throws -> [DotWorkspaceSnapshot] {
        let sandboxRoot = DotSandboxManager.shared.sandboxURL(for: dotId)
        let snapshotsBase = sandboxRoot
            .appendingPathComponent("scratch", isDirectory: true)
            .appendingPathComponent(".snapshots", isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: snapshotsBase.path) else {
            return []
        }

        let entries = try fm.contentsOfDirectory(atPath: snapshotsBase.path)
        var snapshots: [DotWorkspaceSnapshot] = []

        for entry in entries {
            let entryURL = snapshotsBase.appendingPathComponent(entry, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryURL.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let snapId = UUID(uuidString: entry) else {
                continue
            }

            let metaURL = snapshotsBase.appendingPathComponent("\(entry).meta.json")
            if let metaData = try? Data(contentsOf: metaURL),
               let decoded = try? JSONDecoder().decode(DotWorkspaceSnapshot.self, from: metaData) {
                snapshots.append(decoded)
            } else {
                let attrs = try? fm.attributesOfItem(atPath: entryURL.path)
                let created = (attrs?[.creationDate] as? Date) ?? Date()
                let subpaths = (try? fm.subpathsOfDirectory(atPath: entryURL.path))?.sorted() ?? []
                let snapshot = DotWorkspaceSnapshot(
                    snapshotId: snapId,
                    dotId: dotId,
                    createdAt: created,
                    snapshotURL: entryURL,
                    filePaths: subpaths
                )
                snapshots.append(snapshot)
            }
        }

        return snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    /// Deletes a workspace snapshot and its metadata.
    public func deleteSnapshot(_ snapshot: DotWorkspaceSnapshot) throws {
        let fm = FileManager.default
        let metaURL = snapshot.snapshotURL.deletingLastPathComponent()
            .appendingPathComponent("\(snapshot.snapshotId.uuidString).meta.json")

        if fm.fileExists(atPath: snapshot.snapshotURL.path) {
            try fm.removeItem(at: snapshot.snapshotURL)
        }
        if fm.fileExists(atPath: metaURL.path) {
            try? fm.removeItem(at: metaURL)
        }
    }

    /// Deletes a snapshot by its UUID.
    public func deleteSnapshot(id snapshotId: UUID, for dotId: UUID) throws {
        let sandboxRoot = DotSandboxManager.shared.sandboxURL(for: dotId)
        let snapshotURL = sandboxRoot
            .appendingPathComponent("scratch", isDirectory: true)
            .appendingPathComponent(".snapshots", isDirectory: true)
            .appendingPathComponent(snapshotId.uuidString, isDirectory: true)

        let snapshot = DotWorkspaceSnapshot(
            snapshotId: snapshotId,
            dotId: dotId,
            createdAt: Date(),
            snapshotURL: snapshotURL,
            filePaths: []
        )
        try deleteSnapshot(snapshot)
    }
}
