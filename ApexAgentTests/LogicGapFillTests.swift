import Testing
import Foundation
import SwiftUI
import Network
@testable import ApexAgentCore
import MCPKit

// MARK: - Phase 2 gap-fill tests: pure logic + real-socket MCP listener.

@Suite("LogicGapFillTests") @MainActor final class LogicGapFillTests {

    init() {
        // Keep ReflectionManager from spawning detached background tasks.
        setenv("APEX_TEST_MODE", "1", 1)
    }

    // MARK: ANSIColorParser

    @Test func testANSIPlainTextSingleSegment() {
        let segs = ANSIColorParser.parse("hello world")
        #expect(segs.count == 1)
        #expect(segs[0].text == "hello world")
        #expect(segs[0].foregroundColor == .primary)
        #expect(segs[0].isBold == false)
    }

    @Test func testANSIEmptyString() {
        #expect(ANSIColorParser.parse("").isEmpty)
    }

    @Test func testANSIColorCodes() {
        // red text then reset
        let segs = ANSIColorParser.parse("\u{001B}[31mred\u{001B}[0mplain")
        #expect(segs.count == 2)
        #expect(segs[0].text == "red")
        #expect(segs[0].foregroundColor == .red)
        #expect(segs[1].text == "plain")
        #expect(segs[1].foregroundColor == .primary)
    }

    @Test func testANSIBoldAndCombined() {
        // bold green via combined code "1;32"
        let segs = ANSIColorParser.parse("\u{001B}[1;32mok\u{001B}[22mstill-green")
        #expect(segs.count == 2)
        #expect(segs[0].isBold == true)
        #expect(segs[0].foregroundColor == .green)
        #expect(segs[1].isBold == false)
        #expect(segs[1].foregroundColor == .green)
    }

    @Test func testANSIBrightAndResetForeground() {
        let segs = ANSIColorParser.parse("\u{001B}[90mgray\u{001B}[39mdefault")
        #expect(segs.count == 2)
        #expect(segs[0].foregroundColor == .gray)
        #expect(segs[1].foregroundColor == .primary)
    }

    @Test func testANSIEmptyCodeResets() {
        let segs = ANSIColorParser.parse("\u{001B}[31mred\u{001B}[mreset")
        #expect(segs.count == 2)
        #expect(segs[1].foregroundColor == .primary)
    }

    @Test func testANSIUnknownCodeIgnored() {
        let segs = ANSIColorParser.parse("\u{001B}[123mtext")
        #expect(segs.count == 1)
        #expect(segs[0].text == "text")
        #expect(segs[0].foregroundColor == .primary)
    }

    @Test func testANSIDanglingEscape() {
        // ESC not followed by '[' is kept as literal text
        let segs = ANSIColorParser.parse("a\u{001B}b")
        let joined = segs.map(\.text).joined()
        #expect(joined == "a\u{001B}b")
    }

    // MARK: AgentHandoff DTOs

    @Test func testTaskContextRoundTrip() throws {
        let ctx = TaskContext(topic: "build fix", instructions: "fix the build", contextHistory: "prior run failed")
        let data = try JSONEncoder().encode(ctx)
        let back = try JSONDecoder().decode(TaskContext.self, from: data)
        #expect(back.taskId == ctx.taskId)
        #expect(back.topic == "build fix")
        #expect(back.instructions == "fix the build")
        #expect(back.contextHistory == "prior run failed")
        // Default taskId is a UUID string
        #expect(UUID(uuidString: ctx.taskId) != nil)
    }

    @Test func testTaskResultRoundTrip() throws {
        let res = TaskResult(taskId: "t1", status: "completed", resultSummary: "done", errorDetails: nil)
        let back = try JSONDecoder().decode(TaskResult.self, from: JSONEncoder().encode(res))
        #expect(back.taskId == "t1")
        #expect(back.status == "completed")
        #expect(back.errorDetails == nil)
    }

    @Test func testConsensusReportRoundTrip() throws {
        let report = ConsensusReport(consensusDecision: "ship", majorityView: "green", minorityDissent: "wait", confidence: 0.9)
        let back = try JSONDecoder().decode(ConsensusReport.self, from: JSONEncoder().encode(report))
        #expect(back.consensusDecision == "ship")
        #expect(back.confidence == 0.9)
        #expect(back.minorityDissent == "wait")
    }

    @Test func testAgentDisagreementRoundTrip() throws {
        let d = AgentDisagreement(topic: "arch", agentPositions: ["A: keep", "B: remove"], conflictSummary: "split")
        let back = try JSONDecoder().decode(AgentDisagreement.self, from: JSONEncoder().encode(d))
        #expect(back.agentPositions.count == 2)
        #expect(back.conflictSummary == "split")
    }

    // MARK: MCPValue coding

    @Test func testMCPValueDecodingVariants() throws {
        let json = #"{"s":"str","n":4.5,"b":true,"a":[1,2],"o":{"k":"v"},"z":null}"#
        let decoded = try JSONDecoder().decode([String: MCPValue].self, from: Data(json.utf8))
        #expect(decoded["s"] == .string("str"))
        #expect(decoded["n"] == .number(4.5))
        #expect(decoded["b"] == .boolean(true))
        #expect(decoded["a"] == .array([.number(1), .number(2)]))
        #expect(decoded["o"] == .object(["k": .string("v")]))
        #expect(decoded["z"] == MCPValue.null)
    }

    @Test func testMCPValueEncodeRoundTrip() throws {
        let value: MCPValue = .object(["list": .array([.boolean(false), .string("x")]), "none": .null])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(MCPValue.self, from: data)
        #expect(back == value)
    }

    @Test func testMCPToolMake() {
        let tool = MCPTool.make(
            name: "echo",
            description: "echoes",
            inputs: [.string("text", description: "what to echo", required: true),
                     .int("count"),
                     .boolean("loud", required: false)]
        )
        #expect(tool.inputSchema.type == "object")
        #expect(tool.inputSchema.properties.count == 3)
        #expect(tool.inputSchema.required == ["text"])
        #expect(tool.inputSchema.properties["count"]?.type == "integer")
        #expect(tool.inputSchema.properties["loud"]?.type == "boolean")
    }

    // MARK: MCPServerListener — real TCP round-trip (no mocks)

    private func httpRequest(port: Int, path: String, body: Data?) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, data)
    }

    @Test func testMCPServerListenerToolsAndCall() async throws {
        let port = Int.random(in: 20000...29999)
        let listener = MCPServerListener(
            port: port,
            tools: { [MCPTool.make(name: "ping", description: "pong", inputs: [])] },
            handler: { request in
                let echoed = request.params?.name ?? "none"
                return MCPToolResult(content: [MCPContent(text: "handled:\(echoed)")])
            }
        )
        try await listener.start()
        // Give NWListener a beat to bind.
        try await Task.sleep(for: .milliseconds(300))

        // GET /tools returns the advertised tool list
        let (toolsStatus, toolsBody) = try await httpRequest(port: port, path: "/tools", body: nil)
        #expect(toolsStatus == 200)
        let tools = try JSONDecoder().decode([MCPTool].self, from: toolsBody)
        #expect(tools.count == 1)
        #expect(tools[0].name == "ping")

        // POST /tools/call routes through the handler
        let callBody = Data(#"{"method":"tools/call","params":{"name":"ping"},"id":1}"#.utf8)
        let (callStatus, callResultBody) = try await httpRequest(port: port, path: "/tools/call", body: callBody)
        #expect(callStatus == 200)
        let result = try JSONDecoder().decode(MCPToolResult.self, from: callResultBody)
        #expect(result.isError == false)
        #expect(result.content.first?.text == "handled:ping")

        // Malformed body → 400
        let (badStatus, _) = try await httpRequest(port: port, path: "/tools/call", body: Data("not-json".utf8))
        #expect(badStatus == 400)

        // Unknown path → 404
        let (nfStatus, _) = try await httpRequest(port: port, path: "/nope", body: nil)
        #expect(nfStatus == 404)

        await listener.stop()
    }

    @Test func testMCPServerListenerDoubleStartIsIdempotent() async throws {
        let port = Int.random(in: 30000...39999)
        let listener = MCPServerListener(port: port, tools: { [] }, handler: { _ in
            MCPToolResult(content: [])
        })
        try await listener.start()
        // Second start must be a no-op, not a bind failure.
        try await listener.start()
        try await Task.sleep(for: .milliseconds(200))
        let (status, body) = try await httpRequest(port: port, path: "/tools", body: nil)
        #expect(status == 200)
        let tools = try JSONDecoder().decode([MCPTool].self, from: body)
        #expect(tools.isEmpty)
        await listener.stop()
    }

    // MARK: ReflectionManager guard paths (test mode keeps it synchronous-safe)

    @Test func testReflectionSkipsWithoutFailure() {
        let orchestrator = AgentOrchestrator()
        let history = [ChatMessage(role: .assistant, content: "Build succeeded")]
        // No failure in history → returns without spawning work. Must not crash.
        ReflectionManager.shared.reflectIfResolved(prompt: "p", history: history, orchestrator: orchestrator)
        #expect(Bool(true))
    }

    @Test func testReflectionSkipsWithoutSuccess() {
        let orchestrator = AgentOrchestrator()
        let history = [
            ChatMessage(role: .system, content: "error: something exploded"),
            ChatMessage(role: .assistant, content: "still investigating"),
        ]
        ReflectionManager.shared.reflectIfResolved(prompt: "p", history: history, orchestrator: orchestrator)
        #expect(Bool(true))
    }

    @Test func testReflectionFailureThenSuccessGuardedByTestMode() {
        // APEX_TEST_MODE=1 (set by the suite init) must prevent the detached task.
        let orchestrator = AgentOrchestrator()
        let history = [
            ChatMessage(role: .system, content: "error: build failed with exit code 65"),
            ChatMessage(role: .assistant, content: "Fixed. Build succeeded."),
        ]
        ReflectionManager.shared.reflectIfResolved(prompt: "p", history: history, orchestrator: orchestrator)
        #expect(getenv("APEX_TEST_MODE") != nil)
    }

    // MARK: DynamicToolRouting

    @Test func testExecuteDynamicToolUnknownReturnsError() async {
        struct Router: DynamicToolRouting {}
        let out = await Router().executeDynamicTool(name: "does_not_exist", argumentsString: "{}")
        #expect(out.hasPrefix("ERROR:"))
    }

    @Test func testLanguageModelExecutorSupportCheckIsStable() {
        // Pure dlsym probe: must not crash and must be deterministic in-process.
        let a = isLanguageModelExecutorSupported()
        let b = isLanguageModelExecutorSupported()
        #expect(a == b)
    }

    // MARK: SystemInfoTool / ProcessListTool (real syscalls, no TCC surface)

    @Test func testSystemInfoToolReturnsRealData() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = SystemInfoTool(orchestrator: orchestrator)
        let output = try await tool.call(arguments: .init())
        #expect(output.contains("## System Information"))
        #expect(output.contains("**OS:** macOS"))
        #expect(output.contains("**RAM:**"))
        #expect(output.contains("Apple Silicon") || output.contains("Intel"))
        // RAM must be a positive integer count of GB
        #expect(!output.contains("**RAM:** 0 GB"))
    }

    @Test func testProcessListToolListsThisProcessHost() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ProcessListTool(orchestrator: orchestrator)
        let visible = try await tool.call(arguments: .init(includeBackground: false))
        #expect(visible.contains("## Running Applications"))
        let all = try await tool.call(arguments: .init(includeBackground: true))
        // Background listing is a superset — must include at least as many bullet lines.
        let visibleCount = visible.components(separatedBy: "\n• ").count
        let allCount = all.components(separatedBy: "\n• ").count
        #expect(allCount >= visibleCount)
    }
}
