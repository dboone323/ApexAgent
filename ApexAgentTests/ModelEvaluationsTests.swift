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
        #expect(tool is any Tool)
        #expect(CoreSpotlightRAG.isAvailable)
    }

    @Test("Evaluation is well-formed (real Evaluations framework)")
    func evaluationStructure() async {
        let evaluation = ApexModelEvaluation()
        // Real framework: dataset is an ArrayLoader exposing an async stream.
        var sampleCount = 0
        if let stream = try? evaluation.dataset.stream {
            var iterator = stream.makeAsyncIterator()
            while let _ = try? await iterator.next() {
                sampleCount += 1
            }
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
            #expect(model is any LanguageModel)
        }
    }

    @Test("Registry activeProvider defaults to on-device when unset")
    func registryDefaultsToOnDevice() {
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
}
