import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 85 — Team Playbook Execution Graph & Compensation Gate Tests")
struct PlaybookExecutionAuditorTests {

    @Test("Valid playbook DAG passes audit with correct topological ordering and 100% score")
    func validPlaybookPasses() {
        let stages = [
            PlaybookStageNode(
                id: "stage-triage",
                name: "Intake Triage",
                dependencies: [],
                isMutating: false,
                requiredRoleIds: ["chief_of_staff"],
                promptTemplate: "Review issue #{{issue_id}}"
            ),
            PlaybookStageNode(
                id: "stage-patch",
                name: "Apply Surgical Patch",
                dependencies: ["stage-triage"],
                isMutating: true,
                compensationStageId: "stage-rollback",
                requiredRoleIds: ["code_architect"],
                promptTemplate: "Apply patch to branch {{target_branch}}"
            ),
            PlaybookStageNode(
                id: "stage-rollback",
                name: "Rollback Changes",
                dependencies: [],
                isMutating: false,
                requiredRoleIds: ["code_architect"],
                promptTemplate: "Revert git working tree"
            ),
            PlaybookStageNode(
                id: "stage-verify",
                name: "Verify Tests",
                dependencies: ["stage-patch"],
                isMutating: false,
                requiredRoleIds: ["automator"],
                promptTemplate: "Run xcodebuild test"
            )
        ]

        let variables = [
            "issue_id": "402",
            "target_branch": "feat/autonomous-patch"
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages, variables: variables)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.totalStagesCount == 4)
        #expect(report.unresolvedDependencies.isEmpty)
        #expect(report.unboundVariables.isEmpty)
        #expect(report.missingCompensations.isEmpty)
        #expect(report.violations.isEmpty)

        // Verify topological order: stage-triage precedes stage-patch, which precedes stage-verify
        let triageIdx = report.topologicalOrder.firstIndex(of: "stage-triage")!
        let patchIdx = report.topologicalOrder.firstIndex(of: "stage-patch")!
        let verifyIdx = report.topologicalOrder.firstIndex(of: "stage-verify")!
        #expect(triageIdx < patchIdx)
        #expect(patchIdx < verifyIdx)
    }

    @Test("Cycle in playbook dependency graph is accurately detected and fails audit")
    func cycleDetectionFails() {
        // Cyclic graph: A -> B -> C -> A
        let stages = [
            PlaybookStageNode(id: "node-a", name: "A", dependencies: ["node-c"]),
            PlaybookStageNode(id: "node-b", name: "B", dependencies: ["node-a"]),
            PlaybookStageNode(id: "node-c", name: "C", dependencies: ["node-b"])
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages)

        #expect(!report.passed)
        #expect(report.topologicalOrder.isEmpty)
        #expect(report.violations.contains { $0.code == "CYCLIC_DEPENDENCY" })

        // Check cycle path detection helper
        let cyclePath = PlaybookExecutionAuditor.detectCyclePath(stages: stages)
        #expect(cyclePath != nil)
        #expect((cyclePath ?? []).count >= 3)
    }

    @Test("Unresolved dependency on non-existent stage triggers UNRESOLVED_DEPENDENCY")
    func unresolvedDependencyFails() {
        let stages = [
            PlaybookStageNode(id: "stage-b", name: "B", dependencies: ["stage-nonexistent"])
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "UNRESOLVED_DEPENDENCY" })
        #expect(report.unresolvedDependencies.contains("stage-b->stage-nonexistent"))
    }

    @Test("Variable interpolation correctly replaces tokens and catches unbound variables")
    func variableInterpolation() {
        let template = "Triage PR #{{pr_number}} for repo ${repo_name} using model {{model_id}}"
        let variables = ["pr_number": "42", "repo_name": "ApexAgent"]

        let (interpolated, unbound) = PlaybookExecutionAuditor.interpolateVariables(
            template: template,
            variables: variables
        )

        #expect(interpolated.contains("Triage PR #42 for repo ApexAgent using model {{model_id}}"))
        #expect(unbound == ["model_id"])

        let stages = [
            PlaybookStageNode(id: "test-var", name: "Var Test", promptTemplate: template)
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages, variables: variables)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "UNBOUND_VARIABLE" })
        #expect(report.unboundVariables.contains("model_id"))
    }

    @Test("Mutating stage without compensation logs MISSING_COMPENSATION_STAGE violation")
    func missingCompensationViolation() {
        let stages = [
            PlaybookStageNode(id: "stage-mutating", name: "Mutating Step", isMutating: true, compensationStageId: nil)
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages)

        #expect(report.passed) // Non-fatal violation
        #expect(report.score < 100.0)
        #expect(report.missingCompensations.contains("stage-mutating"))
        #expect(report.violations.contains { $0.code == "MISSING_COMPENSATION_STAGE" })
    }

    @Test("Mutating stage with non-existent compensation logs fatal INVALID_COMPENSATION_TARGET")
    func invalidCompensationTargetFails() {
        let stages = [
            PlaybookStageNode(id: "stage-mutating", name: "Mutating", isMutating: true, compensationStageId: "ghost-rollback")
        ]

        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: stages)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_COMPENSATION_TARGET" })
    }

    @Test("Empty playbook returns fatal EMPTY_PLAYBOOK_GRAPH violation")
    func emptyPlaybookFails() {
        let report = PlaybookExecutionAuditor.auditExecutionGraph(stages: [])

        #expect(!report.passed)
        #expect(report.score == 0.0)
        #expect(report.violations.contains { $0.code == "EMPTY_PLAYBOOK_GRAPH" })
    }
}
