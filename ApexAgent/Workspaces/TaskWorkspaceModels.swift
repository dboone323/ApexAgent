import Foundation

// MARK: - Task Isolation Types

public enum TaskIsolationType: Sendable, Equatable {
    case worktree(branch: String?)
    case ephemeralDirectory
    case microVM
}

// MARK: - Task Workspace Retention Policy

public enum TaskWorkspaceRetentionPolicy: String, Sendable, Equatable, Codable {
    case cleanupAlways = "cleanup_always"
    case keepOnFailure = "keep_on_failure"
    case retained = "retained"
}

// MARK: - Task Completion Status

public enum TaskCompletionStatus: String, Sendable, Equatable {
    case succeeded = "succeeded"
    case failed = "failed"
    case cancelled = "cancelled"
}

// MARK: - Task Workspace State

public enum TaskWorkspaceState: String, Sendable, Equatable {
    case active = "active"
    case reviewing = "reviewing"
    case landed = "landed"
    case rejected = "rejected"
    case cleanedUp = "cleaned_up"
    case retained = "retained"
}

// MARK: - Task Workspace Error

public enum TaskWorkspaceError: Error, LocalizedError, Sendable, Equatable {
    case pathEscape(attempted: String, workspaceRoot: String)
    case directoryCreationFailed(String)
    case worktreeCreationFailed(String)
    case worktreeRemovalFailed(String)
    case workspaceNotFound(String)
    case invalidState(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .pathEscape(let attempted, let workspaceRoot):
            return "ERROR: Path escape violation: '\(attempted)' resolves outside isolated workspace '\(workspaceRoot)'"
        case .directoryCreationFailed(let msg):
            return "ERROR: Failed to create isolated directory: \(msg)"
        case .worktreeCreationFailed(let msg):
            return "ERROR: Failed to create git worktree: \(msg)"
        case .worktreeRemovalFailed(let msg):
            return "ERROR: Failed to remove git worktree: \(msg)"
        case .workspaceNotFound(let id):
            return "ERROR: Task workspace '\(id)' not found"
        case .invalidState(let msg):
            return "ERROR: Invalid workspace state: \(msg)"
        case .executionFailed(let msg):
            return "ERROR: Execution failed: \(msg)"
        }
    }
}

// MARK: - Task Changed File

public struct TaskChangedFile: Sendable, Equatable {
    public enum ChangeType: String, Sendable, Equatable {
        case added = "added"
        case modified = "modified"
        case deleted = "deleted"
    }

    public let path: String
    public let changeType: ChangeType
    public let byteCount: Int

    public init(path: String, changeType: ChangeType, byteCount: Int = 0) {
        self.path = path
        self.changeType = changeType
        self.byteCount = byteCount
    }
}

// MARK: - Task Review Proposal

public struct TaskReviewProposal: Sendable, Equatable {
    public let taskID: String
    public let workspacePath: String
    public let changedFiles: [TaskChangedFile]
    public let diffSummary: String
    public let proposedAt: Date
    public let isEligibleForLanding: Bool

    public init(
        taskID: String,
        workspacePath: String,
        changedFiles: [TaskChangedFile],
        diffSummary: String,
        proposedAt: Date = Date(),
        isEligibleForLanding: Bool = true
    ) {
        self.taskID = taskID
        self.workspacePath = workspacePath
        self.changedFiles = changedFiles
        self.diffSummary = diffSummary
        self.proposedAt = proposedAt
        self.isEligibleForLanding = isEligibleForLanding
    }
}

// MARK: - Task Landing Result

public struct TaskLandingResult: Sendable, Equatable {
    public let succeeded: Bool
    public let taskID: String
    public let reason: String
    public let landedFiles: [String]
    public let timestamp: Date

    public init(
        succeeded: Bool,
        taskID: String,
        reason: String,
        landedFiles: [String],
        timestamp: Date = Date()
    ) {
        self.succeeded = succeeded
        self.taskID = taskID
        self.reason = reason
        self.landedFiles = landedFiles
        self.timestamp = timestamp
    }
}
