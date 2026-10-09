import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 79 — Speculative Tool Execution DAG & Transaction Rollback Gate Tests")
struct SpeculativeExecutionAuditorTests {

    @Test("Valid acyclic graph with read-only speculative steps passes audit with 100% score")
    func validAcyclicGraphPasses() {
        let steps = [
            SpeculativeStepNode(id: "s1", toolName: "read_file", dependsOn: [], isSpeculative: true),
            SpeculativeStepNode(id: "s2", toolName: "file_search", dependsOn: ["s1"], isSpeculative: true),
            SpeculativeStepNode(id: "s3", toolName: "query_logs", dependsOn: ["s1"], isSpeculative: true),
            SpeculativeStepNode(id: "s4", toolName: "get_system_info", dependsOn: ["s2", "s3"], isSpeculative: true)
        ]

        let report = SpeculativeExecutionAuditor.auditExecutionGraph(steps: steps)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.isAcyclic)
        #expect(report.detectedCycle == nil)
        #expect(report.allSpeculativeStepsSideEffectFree)
        #expect(report.violations.isEmpty)

        let order = report.executionOrder
        #expect(order != nil)
        #expect(order?.first == "s1")
        #expect(order?.last == "s4")
    }

    @Test("Dependency cycle is detected and flagged as DEPENDENCY_CYCLE_DETECTED")
    func cycleDetected() {
        // s1 -> s2 -> s3 -> s1
        let steps = [
            SpeculativeStepNode(id: "s1", toolName: "read_file", dependsOn: ["s3"], isSpeculative: true),
            SpeculativeStepNode(id: "s2", toolName: "file_search", dependsOn: ["s1"], isSpeculative: true),
            SpeculativeStepNode(id: "s3", toolName: "query_logs", dependsOn: ["s2"], isSpeculative: true)
        ]

        let report = SpeculativeExecutionAuditor.auditExecutionGraph(steps: steps)
        #expect(!report.passed)
        #expect(!report.isAcyclic)
        #expect(report.detectedCycle != nil)
        #expect(report.violations.contains { $0.code == "DEPENDENCY_CYCLE_DETECTED" })
    }

    @Test("Mutating tool in speculative mode triggers MUTATING_SPECULATIVE_TOOL violation")
    func mutatingToolInSpeculativeModeFails() {
        let steps = [
            SpeculativeStepNode(id: "s1", toolName: "run_shell_command", dependsOn: [], isSpeculative: true)
        ]

        let report = SpeculativeExecutionAuditor.auditExecutionGraph(steps: steps)
        #expect(!report.passed)
        #expect(!report.allSpeculativeStepsSideEffectFree)
        #expect(report.violations.contains { $0.code == "MUTATING_SPECULATIVE_TOOL" })
    }

    @Test("Mutating confirmed step without rollback handler triggers warning violation")
    func missingRollbackHandlerFlagged() {
        let steps = [
            // Confirmed mutating step without rollback handler
            SpeculativeStepNode(id: "s1", toolName: "write_file", dependsOn: [], isSpeculative: false, hasRollbackHandler: false)
        ]

        let report = SpeculativeExecutionAuditor.auditExecutionGraph(steps: steps)
        #expect(report.violations.contains { $0.code == "MISSING_ROLLBACK_HANDLER" })
    }

    @Test("Non-existent dependency target triggers UNKNOWN_DEPENDENCY_TARGET violation")
    func unknownDependencyTargetFails() {
        let steps = [
            SpeculativeStepNode(id: "s1", toolName: "read_file", dependsOn: ["missing_step_id"], isSpeculative: true)
        ]

        let report = SpeculativeExecutionAuditor.auditExecutionGraph(steps: steps)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "UNKNOWN_DEPENDENCY_TARGET" })
    }
}
