import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 65 — Multi-Agent Session Coordination & Deadlock Prevention Gate Tests")
struct SessionCoordinationAuditorTests {

    @Test("Healthy hierarchical delegation tree passes with score 100.0")
    func healthyDelegationTreePasses() {
        let rootId = UUID()
        let child1Id = UUID()
        let child2Id = UUID()

        let sessions = [
            AgentSessionNode(
                id: rootId,
                agentName: "Chief of Staff",
                depth: 0,
                messageCount: 12,
                status: .active
            ),
            AgentSessionNode(
                id: child1Id,
                agentName: "Code Architect",
                parentSessionId: rootId,
                depth: 1,
                messageCount: 8,
                status: .active
            ),
            AgentSessionNode(
                id: child2Id,
                agentName: "Researcher",
                parentSessionId: rootId,
                depth: 1,
                messageCount: 4,
                status: .active
            )
        ]

        let report = SessionCoordinationAuditor.audit(sessions: sessions)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.detectedDeadlocks.isEmpty)
        #expect(report.violations.isEmpty)
    }

    @Test("Mutual deadlock between two agents is detected")
    func mutualDeadlockIsDetected() {
        let agentA = UUID()
        let agentB = UUID()

        let sessions = [
            AgentSessionNode(
                id: agentA,
                agentName: "Agent A",
                waitingOnSessionId: agentB,
                status: .waitingForSubagent
            ),
            AgentSessionNode(
                id: agentB,
                agentName: "Agent B",
                waitingOnSessionId: agentA,
                status: .waitingForSubagent
            )
        ]

        let report = SessionCoordinationAuditor.audit(sessions: sessions)
        #expect(!report.passed)
        #expect(report.detectedDeadlocks.count == 1)
        #expect(report.violations.contains { $0.ruleId == "COORD-006" && $0.severity == .critical })
    }

    @Test("Three-node circular deadlock is detected")
    func threeNodeDeadlockIsDetected() {
        let nodeA = UUID()
        let nodeB = UUID()
        let nodeC = UUID()

        let sessions = [
            AgentSessionNode(id: nodeA, agentName: "Worker 1", waitingOnSessionId: nodeB, status: .waitingForSubagent),
            AgentSessionNode(id: nodeB, agentName: "Worker 2", waitingOnSessionId: nodeC, status: .waitingForSubagent),
            AgentSessionNode(id: nodeC, agentName: "Worker 3", waitingOnSessionId: nodeA, status: .waitingForSubagent)
        ]

        let report = SessionCoordinationAuditor.audit(sessions: sessions)
        #expect(!report.passed)
        #expect(!report.detectedDeadlocks.isEmpty)
        #expect(report.violations.contains { $0.ruleId == "COORD-006" })
    }

    @Test("Excessive delegation depth is flagged as critical violation")
    func excessiveDelegationDepthFlagged() {
        let deepSession = AgentSessionNode(
            agentName: "Deep Agent",
            depth: 12, // exceeds max of 8
            status: .active
        )

        let report = SessionCoordinationAuditor.audit(sessions: [deepSession])
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "COORD-002" && $0.severity == .critical })
    }

    @Test("Terminated session retaining unclosed processes triggers violation")
    func orphanedProcessesInTerminatedSessionFlagged() {
        let zombieSession = AgentSessionNode(
            agentName: "Zombie Runner",
            activeProcessesCount: 2,
            pendingContinuationsCount: 1,
            status: .completed
        )

        let report = SessionCoordinationAuditor.audit(sessions: [zombieSession])
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "COORD-004" && $0.severity == .high })
        #expect(report.violations.contains { $0.ruleId == "COORD-005" && $0.severity == .high })
    }

    @Test("Session coordination report serializes to JSON")
    func reportSerializesToJSON() {
        let report = SessionCoordinationAuditor.audit(sessions: [])
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
    }
}
