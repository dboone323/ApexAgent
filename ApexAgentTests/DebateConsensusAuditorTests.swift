import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 78 — Multi-Agent Debate Consensus & Byzantine Quorum Gate Tests")
struct DebateConsensusAuditorTests {

    @Test("Simple majority quorum properly resolves approval")
    func simpleMajorityApproval() {
        let votes: [String: AgentVote] = [
            "BotAlpha": .approve,
            "BotBeta": .approve,
            "BotGamma": .reject,
            "BotDelta": .abstain,
            "BotEpsilon": .approve
        ]

        let result = DebateConsensusAuditor.evaluateQuorum(votes: votes, requirement: .simpleMajority)
        #expect(result.quorumMet)
        #expect(result.consensusOutcome == .approve)
        #expect(result.approveVotesCount == 3)
        #expect(result.requiredThreshold == 3)
    }

    @Test("Byzantine 2f+1 quorum verifies resilience against 1 faulty node")
    func byzantineBFTQuorum() {
        // N = 4 agents, tolerating f = 1 fault (N >= 3(1) + 1 = 4). Quorum = 2(1) + 1 = 3.
        let votes: [String: AgentVote] = [
            "Node1": .approve,
            "Node2": .approve,
            "Node3": .approve,
            "Node4": .reject // Byzantine / disagreeing node
        ]

        let result = DebateConsensusAuditor.evaluateQuorum(
            votes: votes,
            requirement: .byzantineFaultTolerant,
            toleratedFaults: 1
        )
        #expect(result.quorumMet)
        #expect(result.consensusOutcome == .approve)
        #expect(result.requiredThreshold == 3)
    }

    @Test("Byzantine population deficit triggers fatal violation")
    func byzantinePopulationDeficitFails() {
        // 3 participants cannot tolerate 1 Byzantine fault under N >= 3f + 1
        let round = DebateRoundDescriptor(
            topic: "Deploy microVM sandbox upgrade",
            roundNumber: 1,
            participants: ["Node1", "Node2", "Node3"],
            votes: ["Node1": .approve, "Node2": .approve, "Node3": .approve]
        )
        let policy = DebateConsensusPolicy(
            requiredQuorum: .byzantineFaultTolerant,
            maxToleratedFaults: 1,
            minParticipants: 3
        )

        let report = DebateConsensusAuditor.auditDebateRound(round, policy: policy)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "BYZANTINE_POPULATION_DEFICIT" })
    }

    @Test("Round ceiling exceeded triggers fatal violation")
    func roundCeilingExceededFails() {
        let round = DebateRoundDescriptor(
            topic: "Database shard migration",
            roundNumber: 6, // Exceeds ceiling 5
            participants: ["Alpha", "Beta", "Gamma"],
            votes: ["Alpha": .approve, "Beta": .reject, "Gamma": .abstain]
        )
        let policy = DebateConsensusPolicy(maxRoundsCeiling: 5)

        let report = DebateConsensusAuditor.auditDebateRound(round, policy: policy)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "DEBATE_ROUND_CEILING_EXCEEDED" })
    }

    @Test("Unanimous quorum requires 100% agreement")
    func unanimousQuorumRequiresAllVotes() {
        let votes: [String: AgentVote] = [
            "A": .approve,
            "B": .approve,
            "C": .approve
        ]
        let passResult = DebateConsensusAuditor.evaluateQuorum(votes: votes, requirement: .unanimous)
        #expect(passResult.quorumMet)
        #expect(passResult.consensusOutcome == .approve)

        let splitVotes: [String: AgentVote] = [
            "A": .approve,
            "B": .approve,
            "C": .reject
        ]
        let failResult = DebateConsensusAuditor.evaluateQuorum(votes: splitVotes, requirement: .unanimous)
        #expect(!failResult.quorumMet)
        #expect(failResult.consensusOutcome == nil)
    }
}
