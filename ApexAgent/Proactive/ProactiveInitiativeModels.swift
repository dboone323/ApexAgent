import Foundation

// MARK: - Proactive Proposal Status (Issue #78, A4)

public enum ProactiveProposalStatus: String, Codable, Sendable, CaseIterable, Equatable {
    case proposed = "proposed"
    case approved = "approved"
    case declined = "declined"
    case executed = "executed"
}

// MARK: - Proactive Proposal Model (Issue #78, A4)

/// A bounded, read-only proposal generated between sessions citing concrete motivating evidence.
///
/// Execution escalates strictly through the existing approval flow:
/// - Unapproved proposals remain read-only suggestions and NEVER execute.
/// - Declined proposals are permanently recorded and cannot be re-proposed.
/// - Outstanding proposed items are bounded by a queue cap (e.g. max 5).
public struct ProactiveProposal: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let evidence: String
    public let proposedAction: String
    public let command: String?
    public let directory: String?
    public let toolName: String
    public var status: ProactiveProposalStatus
    public let createdAt: Date
    public var resolvedAt: Date?
    public var declinedReason: String?
    public var executionOutput: String?

    public init(
        id: UUID = UUID(),
        title: String,
        evidence: String,
        proposedAction: String,
        command: String? = nil,
        directory: String? = nil,
        toolName: String = "run_shell_command",
        status: ProactiveProposalStatus = .proposed,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        declinedReason: String? = nil,
        executionOutput: String? = nil
    ) {
        self.id = id
        self.title = title
        self.evidence = evidence
        self.proposedAction = proposedAction
        self.command = command
        self.directory = directory
        self.toolName = toolName
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.declinedReason = declinedReason
        self.executionOutput = executionOutput
    }

    /// Normalized signature used to detect duplicates and declined repeat proposals.
    public var signature: String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanCmd = command?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(cleanTitle)::\(cleanCmd)"
    }
}

// MARK: - Execution Result

public struct ProposalExecutionResult: Sendable, Equatable {
    public let proposalId: UUID
    public let executed: Bool
    public let approved: Bool
    public let output: String

    public init(
        proposalId: UUID,
        executed: Bool,
        approved: Bool,
        output: String
    ) {
        self.proposalId = proposalId
        self.executed = executed
        self.approved = approved
        self.output = output
    }
}

// MARK: - Errors

public enum ProactiveInitiativeError: LocalizedError, Sendable, Equatable {
    case missingEvidenceCitation(String)
    case queueCapReached(String)
    case previouslyDeclined(String)
    case proposalNotFound(UUID)
    case proposalAlreadyResolved(String)
    case executionNotApproved(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .missingEvidenceCitation(let message):
            return "Missing Evidence Citation: \(message)"
        case .queueCapReached(let message):
            return "Queue Cap Reached: \(message)"
        case .previouslyDeclined(let message):
            return "Previously Declined: \(message)"
        case .proposalNotFound(let id):
            return "Proposal not found with ID: \(id)"
        case .proposalAlreadyResolved(let message):
            return "Proposal Already Resolved: \(message)"
        case .executionNotApproved(let message):
            return "Execution Not Approved: \(message)"
        case .storageError(let message):
            return "Storage Error: \(message)"
        }
    }
}
