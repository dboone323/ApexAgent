import Foundation

// MARK: - Multi-Agent Debate Consensus & Byzantine Quorum Gate (Batch 78)

/// Quorum requirement rules for multi-agent decision making.
public enum QuorumRequirement: String, Sendable, Codable, Equatable {
    case simpleMajority = "simple_majority"       // > 50%
    case twoThirdsSupermajority = "two_thirds"     // >= 66.7%
    case byzantineFaultTolerant = "byzantine_bft" // 2f + 1 where N >= 3f + 1
    case unanimous = "unanimous"                   // 100%
}

/// Agent vote in a debate or consensus round.
public enum AgentVote: String, Sendable, Codable, Equatable {
    case approve = "approve"
    case reject = "reject"
    case abstain = "abstain"
    case timeout = "timeout"
}

/// Policy configuration for multi-agent debates.
public struct DebateConsensusPolicy: Sendable, Codable, Equatable {
    public var requiredQuorum: QuorumRequirement
    public var maxRoundsCeiling: Int
    public var maxToleratedFaults: Int
    public var minParticipants: Int

    public init(
        requiredQuorum: QuorumRequirement = .simpleMajority,
        maxRoundsCeiling: Int = 5,
        maxToleratedFaults: Int = 1,
        minParticipants: Int = 3
    ) {
        self.requiredQuorum = requiredQuorum
        self.maxRoundsCeiling = maxRoundsCeiling
        self.maxToleratedFaults = maxToleratedFaults
        self.minParticipants = minParticipants
    }
}

/// Detailed result of evaluating quorum.
public struct QuorumEvaluationResult: Sendable, Codable, Equatable {
    public let totalVoters: Int
    public let approveVotesCount: Int
    public let rejectVotesCount: Int
    public let abstainVotesCount: Int
    public let timeoutVotesCount: Int
    public let quorumMet: Bool
    public let requiredThreshold: Int
    public let consensusOutcome: AgentVote?
}

/// Violation detected during debate consensus auditing.
public struct DebateAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit descriptor for a completed or in-progress debate round.
public struct DebateRoundDescriptor: Sendable, Codable, Equatable {
    public let topic: String
    public let roundNumber: Int
    public let participants: [String]
    public let votes: [String: AgentVote]
    public let arguments: [String: String]

    public init(
        topic: String,
        roundNumber: Int,
        participants: [String],
        votes: [String: AgentVote],
        arguments: [String: String] = [:]
    ) {
        self.topic = topic
        self.roundNumber = roundNumber
        self.participants = participants
        self.votes = votes
        self.arguments = arguments
    }
}

/// Complete report produced by DebateConsensusAuditor.
public struct DebateConsensusAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let quorumResult: QuorumEvaluationResult
    public let violations: [DebateAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        quorumResult: QuorumEvaluationResult,
        violations: [DebateAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.quorumResult = quorumResult
        self.violations = violations
    }
}

/// Auditor for multi-agent debate quorum, Byzantine fault tolerance, and convergence.
public enum DebateConsensusAuditor {

    // MARK: - Quorum Evaluation

    /// Evaluates if a set of agent votes satisfies the specified quorum rule.
    public static func evaluateQuorum(
        votes: [String: AgentVote],
        requirement: QuorumRequirement,
        toleratedFaults: Int = 1
    ) -> QuorumEvaluationResult {
        let total = votes.count
        var approves = 0
        var rejects = 0
        var abstains = 0
        var timeouts = 0

        for vote in votes.values {
            switch vote {
            case .approve: approves += 1
            case .reject: rejects += 1
            case .abstain: abstains += 1
            case .timeout: timeouts += 1
            }
        }

        let threshold: Int
        switch requirement {
        case .simpleMajority:
            threshold = (total / 2) + 1
        case .twoThirdsSupermajority:
            threshold = Int(ceil(Double(total) * (2.0 / 3.0)))
        case .byzantineFaultTolerant:
            // In a system with f faults where N >= 3f + 1, quorum = 2f + 1
            threshold = 2 * toleratedFaults + 1
        case .unanimous:
            threshold = total
        }

        let quorumMet: Bool
        let outcome: AgentVote?

        if approves >= threshold {
            quorumMet = true
            outcome = .approve
        } else if rejects >= threshold {
            quorumMet = true
            outcome = .reject
        } else {
            quorumMet = false
            outcome = nil
        }

        return QuorumEvaluationResult(
            totalVoters: total,
            approveVotesCount: approves,
            rejectVotesCount: rejects,
            abstainVotesCount: abstains,
            timeoutVotesCount: timeouts,
            quorumMet: quorumMet,
            requiredThreshold: threshold,
            consensusOutcome: outcome
        )
    }

    // MARK: - Debate Round Audit

    /// Audits a debate round against policy constraints (minimum participants, round ceilings, Byzantine thresholds).
    public static func auditDebateRound(
        _ round: DebateRoundDescriptor,
        policy: DebateConsensusPolicy = DebateConsensusPolicy()
    ) -> DebateConsensusAuditReport {
        var violations: [DebateAuditViolation] = []

        // 1. Participant count check
        if round.participants.count < policy.minParticipants {
            violations.append(DebateAuditViolation(
                code: "INSUFFICIENT_PARTICIPANTS",
                message: "Debate round has \(round.participants.count) participant(s); policy requires at least \(policy.minParticipants)."
            ))
        }

        // 2. Byzantine N >= 3f + 1 sanity
        if policy.requiredQuorum == .byzantineFaultTolerant {
            let requiredN = 3 * policy.maxToleratedFaults + 1
            if round.participants.count < requiredN {
                violations.append(DebateAuditViolation(
                    code: "BYZANTINE_POPULATION_DEFICIT",
                    message: "To tolerate \(policy.maxToleratedFaults) fault(s), at least \(requiredN) participants are required (found \(round.participants.count))."
                ))
            }
        }

        // 3. Round ceiling check
        if round.roundNumber > policy.maxRoundsCeiling {
            violations.append(DebateAuditViolation(
                code: "DEBATE_ROUND_CEILING_EXCEEDED",
                message: "Round \(round.roundNumber) exceeds maximum allowable ceiling of \(policy.maxRoundsCeiling) rounds without convergence."
            ))
        }

        // 4. Missing votes check
        for participant in round.participants {
            if round.votes[participant] == nil {
                violations.append(DebateAuditViolation(
                    code: "MISSING_PARTICIPANT_VOTE",
                    message: "Participant '\(participant)' did not register a vote in round \(round.roundNumber).",
                    isFatal: false
                ))
            }
        }

        let quorumResult = evaluateQuorum(
            votes: round.votes,
            requirement: policy.requiredQuorum,
            toleratedFaults: policy.maxToleratedFaults
        )

        if !quorumResult.quorumMet {
            violations.append(DebateAuditViolation(
                code: "QUORUM_NOT_REACHED",
                message: "Votes failed to reach quorum threshold of \(quorumResult.requiredThreshold) under \(policy.requiredQuorum.rawValue).",
                isFatal: false
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty && quorumResult.quorumMet
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 20.0)

        return DebateConsensusAuditReport(
            passed: passed,
            score: score,
            quorumResult: quorumResult,
            violations: violations
        )
    }
}
