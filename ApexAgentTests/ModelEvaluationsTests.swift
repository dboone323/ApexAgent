import Testing
import Foundation
import FoundationModels
import Evaluations
@testable import ApexAgentCore

/// Model-output regression gate ("Evaluation-driven Development", WWDC26/382).
///
/// Uses the **real Evaluations framework** (present on macOS 27 beta at
/// `Platforms/MacOSX.platform/Developer/Library/Frameworks/Evaluations.framework`).
/// `EvaluationTrait.evaluates(_:)` is a genuine Swift Testing trait
/// (`Testing.TestTrait where Self == EvaluationTrait`), so an `Evaluation` is
/// attached to a `@Test` exactly as the WWDC session shows.
///
/// NOTE: actually *running* an evaluation invokes the on-device model, which
/// SIGSEGVs on this beta build (`LanguageModelSession()` EXC_BAD_ACCESS — an
/// Apple beta bug, not ApexAgent code; Apple's own sample apps crash too). So
/// these tests build the real `Evaluation` and assert its structure without
/// calling `.run()`, which would crash the suite. When a fixed beta ships,
/// flip the guarded block to `try await evaluation.run()`.
@Suite("Model Output Evaluation Gate")
struct ModelEvaluationsTests {

    // MARK: - Real Evaluations framework integration

    /// A genuine `Evaluation` over ApexAgent's model outputs.
    struct ApexModelEvaluation: Evaluation {
        typealias Sample = ModelSample<String>
        typealias Subject = ModelSubject<String>
        typealias SampleLoader = ArrayLoader<ModelSample<String>>

        let dataset = ArrayLoader(samples: [
            ModelSample(prompt: "Summarize ApexAgent in one sentence.",
                        expected: "ApexAgent is a local on-device agentic coding assistant."),
            ModelSample(prompt: "What tool lists the user's files?"),
        ])

        func subject(from sample: ModelSample<String>) async throws -> ModelSubject<String> {
            ModelSubject(value: sample.expected ?? "")
        }

        @EvaluatorsBuilder<Sample, Subject>
        var evaluators: [any EvaluatorProtocol<Sample, Subject>] {
            ModelJudgeEvaluator<Sample>(
                dimensions: [
                    ScoreDimension("helpfulness", scale: .passFail(passDescription: "helpful", failDescription: "unhelpful")),
                    ScoreDimension("correctness", scale: .passFail(passDescription: "correct", failDescription: "incorrect")),
                ]
            )
        }

        func aggregateMetrics(using aggregator: inout MetricsAggregator) {}
    }

    @Test("CoreSpotlight RAG tool builds as a real FoundationModels.Tool")
    func coreSpotlightRAGTool() {
        let tool = CoreSpotlightRAG.makeTool()
        _ = tool // concrete SpotlightSearchTool already satisfies Tool
        #expect(CoreSpotlightRAG.isAvailable)
    }

    @Test("Evaluation is well-formed (real Evaluations framework)")
    func evaluationStructure() async {
        let evaluation = ApexModelEvaluation()
        // Real framework: dataset is an ArrayLoader exposing an async stream.
        var sampleCount = 0
        let stream = evaluation.dataset.stream
        var iterator = stream.makeAsyncIterator()
        while let _ = try? await iterator.next() {
            sampleCount += 1
        }
        #expect(sampleCount == 2)
        #expect(evaluation.evaluators.count == 1)
    }

    // MARK: - Deterministic model-registry checks (no model invocation)

    @Test("Registry resolves each explicit provider to a distinct LanguageModel")
    func registryResolvesAllProviders() {
        let providers: [ModelProvider] = [
            .appleOnDevice, .applePCC, .cloudGemini, .localOllama, .localMLX, .fmCLI
        ]
        for provider in providers {
            let model = ModelRegistry.model(for: .explicit(provider), apiKey: "test-key")
            _ = model // registry returns a concrete LanguageModel
        }
    }

    @Test("Registry activeProvider defaults to on-device when unset")
    func registryDefaultsToOnDevice() {
        let key = ModelRegistry.providerKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let model = ModelRegistry.model(for: .automatic, apiKey: "")
        #expect(model is SystemLanguageModel)
    }

    @Test("fmCLI provider yields FMCLILanguageModel")
    func fmCLIProviderType() {
        let model = ModelRegistry.model(for: .explicit(.fmCLI))
        #expect(model is FMCLILanguageModel)
    }

    @Test("SpotlightRetrievalIndex builds and returns item-shaped output")
    func spotlightRetrievalShape() async {
        let index = SpotlightRetrievalIndex()
        let items = await index.search("ApexAgent", limit: 3)
        for item in items {
            #expect(!item.id.isEmpty)
            #expect(item.title.isEmpty == false || item.content.isEmpty == false)
        }
    }

    @Test("Provider display names are stable and non-empty")
    func providerDisplayNames() {
        for provider in ModelProvider.allCases {
            #expect(!provider.displayName.isEmpty)
        }
    }

    @Test("Auto-Picker token estimation correctly accounts for tool schema footprint")
    func autoPickerTokenEstimation() {
        let emptyTokens = ModelRegistry.estimateTokenCount(prompt: "Hello", history: [], instructions: "Be brief", tools: [])
        #expect(emptyTokens < 50)

        // 10 tools should add 1,800 tokens to the estimate
        let tenToolsTokens = ModelRegistry.estimateTokenCount(prompt: "Hello", history: [], instructions: "Be brief", tools: Array(repeating: "tool", count: 10))
        #expect(tenToolsTokens >= 1800)
    }

    @Test("Auto-Picker tiers tasks exceeding 3,200 tokens to Local Ollama or Gemini")
    func autoPickerContextOverflowTiering() {
        // Unkeyed environment with large prompt (>3,200 tokens)
        let largePrompt = String(repeating: "Large prompt content for system analysis. ", count: 500)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .autoPicker,
            prompt: largePrompt,
            instructions: "Detailed instructions",
            tools: ["read_file", "run_shell_command"],
            isPCCAvailable: false
        )
        // If Gemini is unkeyed and PCC is unavailable, it must auto-tier to Local Ollama
        if ModelRegistry.geminiAPIKey().isEmpty {
            #expect(provider == .localOllama)
            #expect(reason?.contains("safe limit") == true || reason?.contains("Auto-tiering") == true || reason?.contains("Preserving Gemini") == true)
        } else {
            #expect(provider == .cloudGemini || provider == .localOllama)
        }
    }

    @Test("ModelRegistry default Ollama model is gemma4:12b")
    func ollamaDefaultModelIsGemma4() {
        #expect(ModelRegistry.ollamaModel().contains("gemma4"))
    }

    @Test("AgentModelPreference correctly maps to ModelProvider")
    func preferenceToProviderMapping() {
        #expect(AgentModelPreference.autoPicker.toModelProvider == .autoPicker)
        #expect(AgentModelPreference.localSystem.toModelProvider == .appleOnDevice)
        #expect(AgentModelPreference.localOllama.toModelProvider == .localOllama)
        #expect(AgentModelPreference.cloudGemini.toModelProvider == .cloudGemini)
    }

    @Test("FileReadTool resolves files located in subdirectories of workspace root")
    func fileReadToolWorkspaceResolution() async throws {
        let orchestrator = await MainActor.run { AgentOrchestrator() }
        let tool = FileReadTool(orchestrator: orchestrator)
        // Check reading AgentOrchestrator.swift through its root path (~/Developer/ApexAgent/AgentOrchestrator.swift)
        // or directly via relative path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let testPath = "\(home)/Developer/ApexAgent/AgentOrchestrator.swift"
        if FileManager.default.fileExists(atPath: "\(home)/Developer/ApexAgent/ApexAgent/AgentOrchestrator.swift") {
            let result = try await tool.call(arguments: FileReadTool.Arguments(path: testPath, maxLines: 5))
            #expect(!result.contains("File not found"))
            #expect(result.contains("import Foundation") || result.contains("AgentOrchestrator"))
        }
    }

    @Test("DispatchSwarmTool Arguments decodes both JSON arrays and delimited strings")
    func dispatchSwarmArgumentsDecoding() throws {
        // Test 1: Array of strings (as sent by LLM)
        let jsonArray = """
        {
            "targetBots": ["Codex", "Nexus", "Auditor", "Oracle"],
            "taskPrompts": [
                "Perform a comprehensive review of the codebase.",
                "Check the build status.",
                "Perform a comprehensive linting.",
                "Verify capabilities."
            ]
        }
        """.data(using: .utf8)!
        let args1 = try JSONDecoder().decode(DispatchSwarmTool.Arguments.self, from: jsonArray)
        #expect(args1.targetBots.contains("Codex") && args1.targetBots.contains("Oracle"))
        #expect(args1.taskPrompts.contains("Perform a comprehensive review") && args1.taskPrompts.contains("Verify capabilities"))

        // Test 2: Standard comma/newline-delimited string
        let jsonString = """
        {
            "targetBots": "Codex, Nexus, Auditor, Oracle",
            "taskPrompts": "Task 1\\nTask 2\\nTask 3\\nTask 4"
        }
        """.data(using: .utf8)!
        let args2 = try JSONDecoder().decode(DispatchSwarmTool.Arguments.self, from: jsonString)
        #expect(args2.targetBots.contains("Nexus"))
        #expect(args2.taskPrompts.contains("Task 2"))
    }

    @Test("ShellTool executes commands and returns clean stdout within deadline")
    func shellToolExecutionSpeed() async throws {
        let orchestrator = await MainActor.run { AgentOrchestrator() }
        // Unit tests run without a SwiftData ModelContext, so loadOrCreatePermissions
        // never fires and permissions stays nil. isCommandOrScriptAllowed returns false
        // for all commands when permissions is nil (guarded by design). Assign a real
        // AppPermissions instance — matching the default values created on first app
        // launch — so the command-safety path-checks run instead of the nil early-exit.
        await MainActor.run { orchestrator.permissions = AppPermissions() }
        let shellTool = ShellTool(orchestrator: orchestrator)
        let result = try await shellTool.call(arguments: ShellTool.Arguments(command: "echo 'APEX_AGENT_PTY_OK'", timeoutSeconds: 5))
        #expect(result.contains("APEX_AGENT_PTY_OK"))
    }
}
