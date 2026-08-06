import Testing
import Foundation
@testable import ApexAgentCore

// Permanent CI gate for the ten local automation workflows.
//
// Each case runs the SAME code the `apexflow` CLI runs — real tools, real
// PTY, real SwiftData, real StateGraph — and fails the suite if a workflow
// stops working. No mocks: a failure here means the agent is actually broken.
//
// Manual run of the identical checks: `swift run apexflow [ids...]`

@MainActor
@Suite("AutomationWorkflowTests") struct AutomationWorkflowTests {

    /// Runs one workflow by id and asserts its self-reported verdict.
    private func expectWorkflow(_ id: Int) async {
        let results = await ApexWorkflows.run(ids: [id])
        guard let result = results.first else {
            Issue.record("workflow \(id) produced no result")
            return
        }
        #expect(result.passed, "\(result.line)")
    }

    @Test func testCodeReviewAndPersistedFindings() async {
        await expectWorkflow(1)
    }

    @Test func testNaturalLanguageProjectQuery() async {
        await expectWorkflow(2)
    }

    @Test func testTestGenerationAndSelectorHealing() async {
        await expectWorkflow(3)
    }

    @Test func testDocumentationGenerationPipeline() async {
        await expectWorkflow(4)
    }

    @Test func testCIFailureTriage() async {
        await expectWorkflow(5)
    }

    @Test func testMultiAgentStateGraphOrchestration() async {
        await expectWorkflow(6)
    }

    @Test func testSchemaDriftMonitoring() async {
        await expectWorkflow(7)
    }

    @Test func testTicketTriageAndRouting() async {
        await expectWorkflow(8)
    }

    @Test func testLegacyModernizationSweep() async {
        await expectWorkflow(9)
    }

    @Test func testProductivityBriefingAndStandup() async {
        await expectWorkflow(10)
    }

    // MARK: - Engine-level invariants
    //
    // These pin the decision logic itself, independent of the end-to-end
    // runs above, so a regression reports which rule broke.

    @Test func testReviewRulesSeverityContract() {
        let findings = CodeReviewRules.scan("""
            let apiKey = "sk_live_abc"
            let x = try! parse()
            let y = value as! Int
            print("debug")
            // TODO: clean up
            """)
        #expect(findings.contains { $0.severity == "error" && $0.message.contains("secret") })
        #expect(findings.contains { $0.severity == "error" && $0.message.contains("try!") })
        #expect(findings.contains { $0.severity == "warning" })
        #expect(findings.contains { $0.severity == "info" })
        #expect(CodeReviewRules.scan("let a = 1").isEmpty)
    }

    @Test func testBuildTriageDistinguishesFlakeFromRegression() {
        #expect(BuildTriage.classify("Sources/A.swift:1:1: error: nope").verdict == .regression)
        #expect(BuildTriage.classify("test timed out after 2.0s").verdict == .flake)
        #expect(BuildTriage.classify("Build complete!").verdict == .green)
        // A compile error beats a timeout when both appear.
        #expect(BuildTriage.classify("timed out\nerror: cannot find 'x'").verdict == .regression)
    }

    @Test func testSelectorHealerDoesNotRewriteValidIdentifiers() {
        let live = ["ComposerSendButton", "SidebarNewChatButton"]
        #expect(SelectorHealer.heal(#"app.buttons["ComposerSendButton"].tap()"#, against: live) == nil)
        #expect(SelectorHealer.heal(#"app.buttons["SendButton"].tap()"#, against: live)?
            .contains("ComposerSendButton") == true)
        // Nothing close enough — refuse to guess.
        #expect(SelectorHealer.heal(#"app.buttons["ZZZ"].tap()"#, against: live) == nil)
    }

    @Test func testSchemaDriftReportsNothingForIdenticalSnapshots() {
        let snapshot = SchemaSnapshot(entries: ["a": ["p:string"], "b": []])
        #expect(SchemaSnapshot.diff(baseline: snapshot, current: snapshot).isEmpty)

        let changed = SchemaSnapshot(entries: ["a": ["p:integer"]])
        let drift = SchemaSnapshot.diff(baseline: snapshot, current: changed)
        #expect(drift.contains { $0.contains("type changed") && $0.contains("a.p") })
        #expect(drift.contains { $0.contains("tool removed: b") })
    }

    @Test func testTicketTriageRoutesToRegisteredAgentsOnly() {
        let tickets = [
            "app crashes on launch",
            "CI build failing",
            "research whether MLX helps",
            "update the README docs",
            "something entirely unclassifiable",
        ]
        for ticket in tickets {
            let route = TicketTriage.route(ticket)
            #expect(AgentRegistry.shared.resolve(name: route.agent) != nil,
                    "routed '\(ticket)' to unregistered agent '\(route.agent)'")
            #expect(["high", "medium", "low"].contains(route.priority))
        }
    }
}
