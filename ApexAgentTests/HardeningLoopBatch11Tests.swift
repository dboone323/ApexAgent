import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch11Tests")
struct HardeningLoopBatch11Tests {
    @Test func testA2AAgentCardMarkdown() {
        let card = A2AAgentCard(
            name: "TestNode",
            description: "Test node",
            version: "1.0.0",
            url: "http://localhost:1338",
            capabilities: A2AAgentCard.A2ACapabilities(streaming: false, pushNotifications: false, stateTransitionHistory: false),
            skills: [],
            defaultInputModes: ["text"],
            defaultOutputModes: ["text"]
        )
        let md = card.formatAsMarkdown()
        #expect(md.contains("TestNode"))
        #expect(md.contains("1.0.0"))
    }

    @Test func testA2AResponseMarkdown() {
        let res = A2AResponse(jsonrpc: "2.0", id: "1", result: nil,
                              error: A2AResponse.A2AError(code: -32601, message: "Method not found"))
        let md = res.formatAsMarkdown()
        #expect(md.contains("Method not found"))
    }

    @Test func testScorecardMarkdown() throws {
        let engine = AgentEvaluationRatingEngine()
        let card = engine.quickAudit()
        let md = card.formatAsMarkdown()
        #expect(md.contains("Overall"))
        #expect(md.contains("OS & Computer Use Automation"))
    }

    @Test func testRegisteredAgentMarkdown() {
        let agent = RegisteredAgent(name: "developer", systemPrompt: "You build software.", allowedTools: ["read_file"], modelPreference: nil)
        let md = agent.formatAsMarkdown()
        #expect(md.contains("developer"))
        #expect(md.contains("read_file"))
    }

    @Test func testWebhookPayloadMarkdown() {
        let md1 = WebhookPayload.json(["a": "1"]).summaryMarkdown()
        #expect(md1.contains("a"))
        let md2 = WebhookPayload.empty.summaryMarkdown()
        #expect(md2.contains("Empty"))
        let md3 = WebhookPayload.text("hello").summaryMarkdown()
        #expect(md3.contains("hello"))
    }

    @Test func testComputerUseStepMarkdown() {
        let step = ComputerUseStep(turn: 1, action: .click(x: 10, y: 20), observation: "ok")
        let md = step.formatAsMarkdown()
        #expect(md.contains("click at"))
    }

    @Test func testSkillManifestMarkdown() {
        let info = SkillManifestInfo(name: "demo", description: "Does things", scriptPath: "/tmp/x.sh", parameterCount: 2)
        let md = info.formatAsMarkdown()
        #expect(md.contains("demo"))
    }

    @Test func testCronScheduleMarkdown() throws {
        let sched = try CronSchedule(expression: "0 9 * * 1-5")
        let md = sched.formatScheduleSummaryMarkdown()
        #expect(md.contains("Weekdays"))
    }

    @Test @MainActor func testProactiveFindingMarkdown() {
        let f = ProactiveScheduler.ProactiveFinding(title: "T", detail: "D", severity: .warning)
        let md = f.formatAsMarkdown()
        #expect(md.contains("Warning"))
    }
}
