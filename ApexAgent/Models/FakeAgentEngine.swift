import Foundation
import AppKit

// MARK: - Deterministic test engine
//
// When the app is launched with APEX_TEST_FAKE_ENGINE=1, the orchestrator uses
// this engine instead of a real LLM. It streams a canned, deterministic
// response with realistic pacing so UI/e2e tests can assert that the agent
// ACTUALLY responds (bubble appears AND is non-empty AND isStreaming flips
// off) without depending on a live model, network, or Apple Intelligence
// availability. This keeps the always-green suite fast and flake-free while
// still exercising the full run/stream/persist lifecycle.
//
// Live endpoint behavior (real AFM3/Gemini/Ollama) is covered separately by
// LiveAgentTriageTests, gated behind APEX_LIVE_E2E.

@MainActor
struct FakeAgentEngine: AgentEngine {
    let orchestrator: AgentOrchestrator

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        // Echo a deterministic, markdown-formatted reply that proves the agent
        // understood the prompt and completed a full stream → isStreaming-off
        // lifecycle. Paced so onUpdate fires several times (exercises the
        // @Observable re-render path) and the run is observably "in flight".
        let reply = """
        **Apex test response**

        You said: "\(prompt)". This is a deterministic reply from the fake test \
        engine, used to validate the agent's response lifecycle end-to-end \
        without a live model.

        - Streaming started and produced incremental tokens.
        - The assistant bubble rendered and updated.
        - Generation completed and `isStreaming` flipped off.
        """

        // Initial think delay (model "cold start").
        try? await Task.sleep(nanoseconds: 400_000_000)

        // Stream the reply in word-sized chunks to mimic token streaming.
        let chunks = reply.components(separatedBy: " ")
        var acc = ""
        for (i, chunk) in chunks.enumerated() {
            acc += (i == 0 ? "" : " ") + chunk
            onUpdate(acc)
            try? await Task.sleep(nanoseconds: 25_000_000) // ~25ms per token
        }

        // Final settle so isStreaming flips off cleanly.
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
