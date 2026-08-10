// Real end-to-end probes: drive the SAME engines the GUI uses, bypassing
// ApexAgentApp.init() (which hangs headless on this beta). Logs each step so
// we can see exactly where a real chat/tool handshake fails/hangs. These are
// NOT gate tests — they require a running local Ollama server + the npx
// filesystem MCP server to be installed.
import Testing
import AppKit
@testable import ApexAgentCore

/// Minimal no-op ToolEventLogger so the MCP probe starts exactly ONE npx server
/// (the one it creates) — it must not also spin up AgentOrchestrator's own MCP
/// server, which would contend for CPU and blow the cold-start warmup.
struct ProbeLogger: ToolEventLogger {
    func logToolStart(name: String, arguments: String) {}
    func logToolEnd(name: String, result: String, status: ToolStatus) {}
    func logToolEvent(_ event: ToolEvent) {}
    func updateToolStatus(name: String, status: ToolStatus) {}
    func shouldConfirmTool(name: String) -> Bool { false }
    func requestConfirmation(
        toolName: String, arguments: String, riskDescription: String,
        oldContent: String?, newContent: String?, filePath: String?
    ) async -> Bool { false }
    func resolveConfirmation(approved: Bool) {}
}

@MainActor
@Suite("ChatProbe", .serialized)
struct ChatProbeTests {

    @Test("real Ollama chat returns a response")
    func realOllamaChat() async throws {
        print("[PROBE] step 1: constructing AgentOrchestrator")
        let orch = AgentOrchestrator()
        orch.modelPreference = .localOllama
        print("[PROBE] step 2: orchestrator ready; provider = \(orch.modelPreference.rawValue)")

        let engine = OllamaAgentEngine(orchestrator: orch)
        print("[PROBE] step 3: OllamaAgentEngine created")

        let instructions = "You are ApexAgent, a concise coding assistant. Use tools when helpful."
        let prompt = "Hello. In ONE short sentence, what can you do and which tools are available?"
        var chunks = 0
        var full = ""
        print("[PROBE] step 4: calling streamResponse (prompt: \(prompt))")

        try await engine.streamResponse(
            prompt: prompt,
            attachments: [],
            history: [],
            instructions: instructions,
            toolCallingMode: .auto
        ) { chunk in
            chunks += 1
            full += chunk
            if chunks <= 5 || chunks % 20 == 0 {
                print("[PROBE]   stream chunk #\(chunks): \(chunk.prefix(60))")
            }
        }

        print("[PROBE] step 5: streamResponse returned")
        print("[PROBE] total chunks = \(chunks), chars = \(full.count)")
        print("[PROBE] === FINAL RESPONSE ===")
        print(full.isEmpty ? "(empty — no response)" : full)
        print("[PROBE] ==========================")
        #expect(chunks > 0, "expected at least one streamed chunk from Ollama")
        #expect(!full.isEmpty, "expected a non-empty response from Ollama")
    }

    @Test("native Apple Foundation Models chat returns a response (beta 5)")
    func nativeAppleChat() async throws {
        // Allow a custom message via env (APEX_FM_PROMPT) for CLI-style runs;
        // default to a deterministic probe string.
        let envPrompt = ProcessInfo.processInfo.environment["APEX_FM_PROMPT"]
        let prompt = envPrompt?.isEmpty == false ? envPrompt! : "Reply with exactly: NATIVE FM OK"
        print("[PROBE] native step 1: constructing AgentOrchestrator (default .localSystem)")
        let orch = AgentOrchestrator()
        orch.modelPreference = .localSystem
        // NativeAppleEngine uses orchestrator.session, populated by resetSession().
        orch.resetSession()
        guard orch.session != nil else {
            throw NSError(domain: "ChatProbe", code: -1, userInfo: [NSLocalizedDescriptionKey: "orchestrator.session was nil after resetSession()"])
        }
        print("[PROBE] native step 2: session initialized; provider = \(orch.modelPreference.rawValue)")

        let engine = NativeAppleEngine(orchestrator: orch)
        print("[PROBE] native step 3: NativeAppleEngine created")

        let instructions = "You are ApexAgent, a concise assistant. Answer briefly."
        var full = ""
        var chunks = 0
        print("[PROBE] native step 4: calling streamResponse (prompt: \(prompt))")

        try await engine.streamResponse(
            prompt: prompt,
            attachments: [],
            history: [],
            instructions: instructions,
            toolCallingMode: .disabled
        ) { chunk in
            full += chunk
            chunks += 1
            if chunks <= 3 { print("[PROBE]   native chunk #\(chunks): \(chunk.prefix(60))") }
        }

        print("[PROBE] native step 5: streamResponse returned")
        print("[PROBE] native total chunks = \(chunks), chars = \(full.count)")
        print("[PROBE] === NATIVE FINAL ===")
        print(full.isEmpty ? "(empty)" : full)
        print("[PROBE] ======================")
        #expect(chunks > 0, "expected at least one chunk from native Apple FM")
        #expect(!full.isEmpty, "expected a non-empty response from native Apple FM on beta 5")
    }

    @Test("MCP filesystem server initializes quickly (no 216s stall)")
    func mcpInitNotStalled() async throws {
        print("[PROBE] MCP: constructing client for filesystem server")
        let client = MCPClient(
            serverName: "Filesystem MCP",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
            logger: ProbeLogger()
        )
        let t0 = Date()
        print("[PROBE] MCP: calling start() (awaits 'running on stdio' readiness gate)")
        try await client.start()
        let elapsed = Date().timeIntervalSince(t0)
        print("[PROBE] MCP: start() returned in \(String(format: "%.1f", elapsed))s")
        #expect(elapsed < 30, "MCP start should complete in <30s, got \(String(format: "%.1f", elapsed))s (was ~216s before the readiness-gate fix)")
        await client.stop()
    }
}
