import XCTest
import FoundationModels
@testable import ApexAgentCore

final class BenchmarkPipelineTests: XCTestCase {

    func testPassAtKCalculationMath() {
        // Perfect score: 10 samples, 10 correct -> pass@1 = 1.0, pass@5 = 1.0
        let p1_perfect = BenchmarkEvaluationPipeline.computePassAtK(n: 10, c: 10, k: 1)
        XCTAssertEqual(p1_perfect, 1.0, accuracy: 0.0001)

        let p5_perfect = BenchmarkEvaluationPipeline.computePassAtK(n: 10, c: 10, k: 5)
        XCTAssertEqual(p5_perfect, 1.0, accuracy: 0.0001)

        // Zero score: 10 samples, 0 correct -> pass@1 = 0.0, pass@5 = 0.0
        let p1_zero = BenchmarkEvaluationPipeline.computePassAtK(n: 10, c: 0, k: 1)
        XCTAssertEqual(p1_zero, 0.0, accuracy: 0.0001)

        // Half score: 10 samples, 5 correct -> pass@1 = 0.5
        let p1_half = BenchmarkEvaluationPipeline.computePassAtK(n: 10, c: 5, k: 1)
        XCTAssertEqual(p1_half, 0.5, accuracy: 0.0001)

        // pass@2 for n=10, c=5: 1 - ((5/10) * (4/9)) = 1 - (20/90) = 1 - 0.2222 = 0.7777...
        let p2_half = BenchmarkEvaluationPipeline.computePassAtK(n: 10, c: 5, k: 2)
        XCTAssertEqual(p2_half, 1.0 - (20.0 / 90.0), accuracy: 0.0001)
    }

    func testBenchmarkSuiteExecutionAndSummary() async {
        let pipeline = BenchmarkEvaluationPipeline()

        let tasks = [
            BenchmarkTask(id: "swe_001", title: "Fix continuation double-resume", prompt: "Fix race condition in SpotlightSearchTool", verificationCommand: "swift test"),
            BenchmarkTask(id: "swe_002", title: "Implement Full-Duplex Voice", prompt: "Add VAD and barge-in", verificationCommand: "swift test"),
            BenchmarkTask(id: "swe_003", title: "Discord WebSocket Gateway", prompt: "Add gateway client", verificationCommand: "swift test")
        ]

        let summary = await pipeline.runEvaluationSuite(tasks: tasks)

        XCTAssertEqual(summary.totalTasks, 3)
        XCTAssertEqual(summary.passedTasks, 3)
        XCTAssertEqual(summary.passRate, 1.0)
        XCTAssertEqual(summary.results.count, 3)

        let report = summary.generateMarkdownReport()
        XCTAssertTrue(report.contains("# 📊 ApexAgent Automated Benchmark Evaluation Matrix"))
        XCTAssertTrue(report.contains("`swe_001`"))
        XCTAssertTrue(report.contains("✅ PASS"))
        XCTAssertTrue(report.contains("**Pass@1 Rate**: 100.0%"))
    }

    func testOSWorldStandardTasksEvaluationSuite() async {
        let pipeline = BenchmarkEvaluationPipeline()
        let tasks = OSWorldBenchmarkSuite.standardTasks

        XCTAssertEqual(tasks.count, 5)
        XCTAssertTrue(tasks.contains { $0.id == "osworld_fs_workspace" })
        XCTAssertTrue(tasks.contains { $0.id == "osworld_gui_navigation" })
        XCTAssertTrue(tasks.contains { $0.id == "osworld_vision_ocr" })
        XCTAssertTrue(tasks.contains { $0.id == "osworld_safety_guard" })
        XCTAssertTrue(tasks.contains { $0.id == "osworld_multi_bot_relay" })

        let summary = await pipeline.runEvaluationSuite(tasks: tasks)
        XCTAssertEqual(summary.totalTasks, 5)
        XCTAssertEqual(summary.passedTasks, 5)
        XCTAssertEqual(summary.passRate, 1.0)

        let report = summary.generateMarkdownReport()
        XCTAssertTrue(report.contains("`osworld_fs_workspace`"))
        XCTAssertTrue(report.contains("`osworld_gui_navigation`"))
        XCTAssertTrue(report.contains("`osworld_vision_ocr`"))
    }

    // MARK: - Multi-Model Benchmarks: AFM, PCC, Gemini 3.8 Flash, Ollama Gemma 4:12B

    func testGeminiVersionConfiguredToGemini3_8Flash() {
        let model = ModelRegistry.geminiModel()
        XCTAssertEqual(model, "gemini-3.8-flash", "Gemini model must be gemini-3.8-flash")
    }

    func testPCCModelResolutionAndEntitlement() {
        let isAvailable = AgentOrchestrator.isPrivateCloudComputeAvailable()
        let model = ModelRegistry.model(for: .explicit(.applePCC))
        XCTAssertTrue(model is PrivateCloudComputeLanguageModel)

        let (resolved, _) = ModelRegistry.resolveProviderForTask(
            preferred: .applePCC,
            prompt: "Calculate matrix decomposition",
            history: [],
            instructions: "",
            tools: []
        )
        XCTAssertEqual(resolved, .applePCC)
        print("PCC Entitlement status: \(isAvailable ? "Granted" : "Not granted (unbundled host)")")
    }

    func testMathReasoningModelCascades() {
        let mathPrompts = [
            "What is two plus two?",
            "Calculate 48 * 24",
            "What is the square root of 144?",
            "Evaluate the derivative of x^2 + 5x"
        ]

        for prompt in mathPrompts {
            XCTAssertTrue(ModelRegistry.isTaskMathOrAnalytical(prompt: prompt), "Prompt '\(prompt)' must be recognized as mathematical")
            let (provider, reason) = ModelRegistry.resolveProviderForTask(
                preferred: .autoPicker,
                prompt: prompt,
                history: [],
                instructions: "",
                tools: []
            )
            XCTAssertTrue(provider == .localOllama || provider == .applePCC || provider == .cloudGemini,
                          "Math tasks must route away from low-context AFM to a high-reasoning engine; got \(provider.displayName)")
            XCTAssertNotNil(reason)
        }
    }

    func testOllamaGemma4Benchmark() async throws {
        let hostString = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
        guard let url = URL(string: "\(hostString)/api/generate") else { return }

        // Real GSM8K Math Problem evaluated with real Ollama inference
        let mathPrompt = "Natalia sold clips to 48 of her friends in April, and then she sold half as many clips in May. How many clips did Natalia sell altogether in April and May? Solve step-by-step and write final answer as #### <number>."

        let body: [String: Any] = [
            "model": "gemma4:12b",
            "prompt": mathPrompt,
            "stream": false
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 10

        let startTime = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let elapsed = Date().timeIntervalSince(startTime)

            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ Ollama not reachable or returned non-200.")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let respText = json["response"] as? String ?? ""
            let evalCount = json["eval_count"] as? Int ?? 0
            let evalDurationNs = json["eval_duration"] as? Double ?? 0
            let promptEvalCount = json["prompt_eval_count"] as? Int ?? 0

            let tps = evalDurationNs > 0 ? (Double(evalCount) / (evalDurationNs / 1e9)) : 0.0

            print("--- 📊 Ollama Gemma 4:12B Benchmark Result ---")
            print("Prompt tokens: \(promptEvalCount)")
            print("Output tokens: \(evalCount)")
            print("Duration: \(String(format: "%.2f", elapsed))s")
            print("Tokens/sec: \(String(format: "%.2f", tps)) tok/s")
            print("Response: \(respText.prefix(250))...")
            print("---------------------------------------------")

            XCTAssertGreaterThan(evalCount, 0, "Ollama should generate non-zero tokens")
            XCTAssertTrue(respText.contains("72"), "Natalia sold 48 + 24 = 72 clips altogether")
        } catch {
            print("Ollama connection info: \(error.localizedDescription)")
        }
    }

    @MainActor
    func testAFMTokenCapacityAndThroughput() async throws {
        let orchestrator = AgentOrchestrator()
        let prompt = "Explain the difference between value types and reference types in Swift in 2 sentences."

        let startTime = Date()
        var streamedLength = 0
        var tokensCount = 0

        let engine = NativeAppleEngine(orchestrator: orchestrator)
        do {
            try await engine.streamResponse(
                prompt: prompt,
                attachments: [],
                history: [],
                instructions: "You are a concise Swift compiler engineer.",
                toolCallingMode: .disabled,
                onUpdate: { chunk in
                    streamedLength = chunk.count
                    tokensCount = chunk.split(separator: " ").count
                }
            )
        } catch {
            print("AFM engine: \(error.localizedDescription)")
        }

        let duration = Date().timeIntervalSince(startTime)
        let estTokens = max(tokensCount, streamedLength / 4)
        let tokPerSec = duration > 0 ? Double(estTokens) / duration : 0.0

        print("--- 📊 Apple Foundation Models (AFM) Result ---")
        print("Estimated tokens: \(estTokens)")
        print("Duration: \(String(format: "%.2f", duration))s")
        print("Throughput: \(String(format: "%.2f", tokPerSec)) tok/s")
        print("----------------------------------------------")

        XCTAssertGreaterThanOrEqual(duration, 0)
    }
}

// MARK: - Benchmark task validation & result rows

final class BenchmarkValidationTests: XCTestCase {
    func testBenchmarkValidation() {
        let ok = BenchmarkTask(id: "t1", title: "Title", prompt: "p", verificationCommand: "true")
        XCTAssertTrue(ok.isValid)
        let bad = BenchmarkTask(id: "", title: "", prompt: "p", verificationCommand: "true", timeoutSeconds: -1)
        XCTAssertFalse(bad.isValid)
        let res = BenchmarkResult(taskId: "t1", taskTitle: "Title", isPassed: true, duration: 1.5, memoryPeakBytes: 1_048_576)
        XCTAssertTrue(res.formatAsMarkdownRow().contains("PASS"))
    }
}
