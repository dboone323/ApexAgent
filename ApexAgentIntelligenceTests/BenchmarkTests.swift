// BenchmarkTests.swift — ApexAgentIntelligenceTests
//
// Performance regression checks for the native Foundation Models path. These
// run in CI without Instruments: they time real `LanguageModelSession`
// generation + profile construction and assert the numbers stay within sane
// bounds. The generation benchmarks skip gracefully when no on-device/PCC
// model can produce output (e.g. beta builds without downloaded weights), so
// they never report a false failure — the latency signal is captured wherever
// the runtime actually generates.
//
// To get the full trace (per-tool spans, token counts) open the app in
// Instruments with the "Foundation Models" template; the `AgentSignpost`
// spans emitted by `apexAuditHooks()` show up there.

import Testing
import Foundation
import FoundationModels
@testable import ApexAgentCore

@Suite("Foundation Models Benchmarks", .serialized)
struct BenchmarkTests {

    // MARK: - Formatting helper

    /// Human-readable seconds for a Duration without relying on the
    /// UnitsFormatStyle shorthand (which isn't available in this SDK).
    private func secs(_ d: Duration) -> String {
        let total = Double(d.components.seconds) + Double(d.components.attoseconds) / 1_000_000_000_000_000_000
        return String(format: "%.3f s", total)
    }

    // MARK: - Model availability (MainActor — calls MainActor-inherited API)

    /// True when at least one native model (on-device or PCC) can generate.
    @MainActor
    private func canGenerate() -> Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        if AgentOrchestrator.isPrivateCloudComputeAvailable() { return true }
        return false
    }

    // MARK: - Deterministic: profile construction + KV prewarm

    /// Builds each live profile and warms its KV cache. No generation required,
    /// so this always runs and guards against regressions in profile assembly
    /// (tool wiring, hook chaining, type-erasure) and prewarm latency.
    @MainActor
    @Test("Profile construction + prewarm latency")
    func testProfileConstructionAndPrewarm() async throws {
        let orchestrator = AgentOrchestrator()
        let prompts = [
            "Summarize the README.",
            "List the files in the current directory.",
            "Write a unit test for the parser."
        ]

        let clock = ContinuousClock()
        var total = Duration.zero
        for (i, prompt) in prompts.enumerated() {
            let profile = ApexAgentProfile(
                instructions: "You are a benchmark agent.",
                model: SystemLanguageModel.default,
                toolCallingMode: .allowed,
                orchestrator: orchestrator,
                reasoningLevel: i == 2 ? .moderate : nil,
                maxResponseTokens: 512
            )
            let start = clock.now
            let session = LanguageModelSession(profile: profile, history: Transcript(entries: []))
            session.prewarm(promptPrefix: Prompt(prompt))
            total += clock.now - start
        }

        let perProfile = total / Double(prompts.count)
        print("[Benchmark] profile construction + prewarm: \(secs(perProfile)) per profile (avg of \(prompts.count))")
        // Construction + prewarm must be cheap; flags heavy profile assembly.
        #expect(perProfile < .seconds(5), "Profile build + prewarm took \(secs(perProfile)); regression?")
    }

    // MARK: - Generation latency (skips when no model can generate)

    /// Times a single `respond(to:)` round-trip through the real instrumented
    /// `ApexAgentProfile`. Skips when the native runtime can't produce output.
    @MainActor
    @Test("Single-prompt generation latency (on-device / PCC)")
    func testSinglePromptGenerationLatency() async throws {
        guard canGenerate() else {
            Issue.record("Skipped: no on-device or PCC model available to generate on this build.")
            return
        }

        let orchestrator = AgentOrchestrator()
        let profile = ApexAgentProfile(
            instructions: "You are a concise benchmark agent. Answer in one sentence.",
            model: SystemLanguageModel.default,
            toolCallingMode: .disallowed,
            orchestrator: orchestrator,
            maxResponseTokens: 256
        )
        let session = LanguageModelSession(profile: profile, history: Transcript(entries: []))
        session.prewarm(promptPrefix: Prompt("What is a closure?"))

        let prompt = "What is a Swift closure in one sentence?"
        let clock = ContinuousClock()
        let start = clock.now
        let response = try await session.respond(to: prompt)
        let elapsed = clock.now - start

        let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            Issue.record("Skipped: model returned empty output (likely no local weights on this build).")
            return
        }

        print("[Benchmark] generate(\"\(prompt)\"): \(secs(elapsed)), \(content.count) chars")
        // Generous upper bound; a healthy on-device/PCC round-trip is well under this.
        #expect(elapsed < .seconds(60), "Generation took \(secs(elapsed)); regression?")
    }

    /// Times a multi-turn conversation (two prompts sharing one session) to
    /// capture context carry-through cost. Skips when no generation occurs.
    @MainActor
    @Test("Multi-turn conversation latency (on-device / PCC)")
    func testMultiTurnConversationLatency() async throws {
        guard canGenerate() else {
            Issue.record("Skipped: no on-device or PCC model available to generate on this build.")
            return
        }

        let orchestrator = AgentOrchestrator()
        let profile = ApexAgentProfile(
            instructions: "You are a concise benchmark agent.",
            model: SystemLanguageModel.default,
            toolCallingMode: .disallowed,
            orchestrator: orchestrator,
            maxResponseTokens: 256
        )
        let session = LanguageModelSession(profile: profile, history: Transcript(entries: []))
        session.prewarm(promptPrefix: Prompt("Continue the conversation."))

        let prompts = ["Name a color.", "Now name a fruit."]
        let clock = ContinuousClock()
        var total = Duration.zero
        var lastContent = ""
        for p in prompts {
            let start = clock.now
            let r = try await session.respond(to: p)
            total += clock.now - start
            lastContent = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lastContent.isEmpty else {
                Issue.record("Skipped: model returned empty output (likely no local weights on this build).")
                return
            }
        }

        let per = total / Double(prompts.count)
        print("[Benchmark] multi-turn: \(secs(per)) avg over \(prompts.count) turns (\(secs(total)) total)")
        #expect(per < .seconds(60), "Multi-turn generation took \(secs(per)); regression?")
    }

    // MARK: - Tool-call profile overhead (no generation)

    /// Confirms the instrumented `SpecializedAgentProfile` (full tool set +
    /// `apexAuditHooks` + `historyTransform` + reasoning level) constructs and
    /// prewarms without generation, and that the reasoning-level modifier path
    /// is exercised. Deterministic; always runs.
    @MainActor
    @Test("Instrumented specialized profile builds with full tool set")
    func testInstrumentedSpecializedProfileBuild() async throws {
        let orchestrator = AgentOrchestrator()
        let clock = ContinuousClock()
        let start = clock.now
        let profile = SpecializedAgentProfile(
            agentType: .developer,
            instructions: "Benchmark the developer agent.",
            model: SystemLanguageModel.default,
            toolCallingMode: .allowed,
            orchestrator: orchestrator,
            reasoningLevel: .moderate,
            maxResponseTokens: 1024
        )
        let session = LanguageModelSession(profile: profile, history: Transcript(entries: []))
        session.prewarm(promptPrefix: Prompt("Review this pull request."))
        let elapsed = clock.now - start
        print("[Benchmark] specialized agent profile build + prewarm: \(secs(elapsed))")
        #expect(elapsed < .seconds(5), "Specialized profile build took \(secs(elapsed)); regression?")
    }
}
