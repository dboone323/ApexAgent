import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 76 — Routine Recorder Deterministic Event Replay Gate Tests")
struct RoutineReplayAuditorTests {

    @Test("Valid recorded steps with bound parameters pass audit with 100% score")
    func validRecordedStepsPass() {
        let baseDate = Date()
        let steps = [
            RecordedStep(action: "open_app", detail: "Xcode", occurredAt: baseDate),
            RecordedStep(action: "shell", detail: "git checkout -b {{branch_name}}", occurredAt: baseDate.addingTimeInterval(1.0)),
            RecordedStep(action: "wait", detail: "500ms", occurredAt: baseDate.addingTimeInterval(2.0)),
            RecordedStep(action: "note", detail: "Branch created successfully", occurredAt: baseDate.addingTimeInterval(3.0))
        ]

        let params = ["branch_name": "feat/my-awesome-feature"]
        let report = RoutineReplayAuditor.auditSteps(steps: steps, parameters: params)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.isMonotonicOrdering)
        #expect(report.isIdempotentSafe)
        #expect(report.unboundVariables.isEmpty)
        #expect(report.violations.isEmpty)
    }

    @Test("Non-monotonic timestamp ordering triggers fatal violation")
    func nonMonotonicTimestampsFail() {
        let now = Date()
        let steps = [
            RecordedStep(action: "open_app", detail: "Terminal", occurredAt: now),
            RecordedStep(action: "shell", detail: "ls -la", occurredAt: now.addingTimeInterval(-10.0)) // earlier than previous!
        ]

        let report = RoutineReplayAuditor.auditSteps(steps: steps)
        #expect(!report.passed)
        #expect(!report.isMonotonicOrdering)
        #expect(report.violations.contains { $0.code == "NON_MONOTONIC_TIMESTAMP" })
    }

    @Test("Destructive shell command triggers DESTRUCTIVE_SHELL_COMMAND violation")
    func destructiveCommandFails() {
        let now = Date()
        let steps = [
            RecordedStep(action: "shell", detail: "rm -rf /tmp/my-project-cache", occurredAt: now)
        ]

        let report = RoutineReplayAuditor.auditSteps(steps: steps)
        #expect(!report.passed)
        #expect(!report.isIdempotentSafe)
        #expect(report.violations.contains { $0.code == "DESTRUCTIVE_SHELL_COMMAND" })
    }

    @Test("Unbound template variable in step detail triggers UNBOUND_TEMPLATE_VARIABLES violation")
    func unboundVariableFails() {
        let now = Date()
        let steps = [
            RecordedStep(action: "shell", detail: "deploy.sh --target {{deploy_target}}", occurredAt: now)
        ]

        let report = RoutineReplayAuditor.auditSteps(steps: steps, parameters: [:])
        #expect(!report.passed)
        #expect(report.unboundVariables.contains("deploy_target"))
        #expect(report.violations.contains { $0.code == "UNBOUND_TEMPLATE_VARIABLES" })
    }

    @Test("Parameter substitution replaces variables cleanly")
    func parameterSubstitutionReplacesVariables() {
        let template = "echo 'Deploying to {{environment}} with cluster {{cluster_id}}'"
        let params = ["environment": "production", "cluster_id": "us-west1-a"]
        let result = RoutineReplayAuditor.substituteParameters(text: template, parameters: params)

        #expect(result.isComplete)
        #expect(result.missingKeys.isEmpty)
        #expect(result.substitutedKeys.count == 2)
        #expect(result.substitutedText == "echo 'Deploying to production with cluster us-west1-a'")
    }
}
