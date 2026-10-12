import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 101 — Universal OpenAI-Compatible Language Model Tests")
struct OpenAICompatibleLanguageModelTests {

    @Test("Valid HTTPS configuration passes wire protocol security audit with 100% score")
    func validHTTPSConfigPasses() {
        let config = OpenAICompatibleConfiguration(
            endpointURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: "sk-proj-1234567890abcdef",
            modelName: "gpt-4o"
        )

        let report = OpenAIWireProtocolAuditor.auditConfiguration(config)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.redactedKey == "sk-...cdef")
        #expect(report.sanitizedEndpoint == "https://api.openai.com/v1/chat/completions")
    }

    @Test("Insecure HTTP endpoint for remote host trips fatal security violation")
    func insecureRemoteHTTPEndpointFails() {
        let config = OpenAICompatibleConfiguration(
            endpointURL: URL(string: "http://api.remote-llm.com/v1/chat/completions")!,
            apiKey: "sk-test",
            modelName: "custom-model"
        )

        let report = OpenAIWireProtocolAuditor.auditConfiguration(config)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INSECURE_HTTP_ENDPOINT" })
    }

    @Test("Localhost HTTP endpoint is permitted for local vLLM / LM Studio development")
    func localhostHTTPEndpointAllowed() {
        let config = OpenAICompatibleConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:1234/v1/chat/completions")!,
            apiKey: "",
            modelName: "local-llama"
        )

        let report = OpenAIWireProtocolAuditor.auditConfiguration(config)
        #expect(report.passed)
        #expect(report.violations.isEmpty)
    }

    @Test("Non-standard endpoint path produces non-fatal warning")
    func nonStandardPathWarns() {
        let config = OpenAICompatibleConfiguration(
            endpointURL: URL(string: "https://api.openai.com/v1/custom_generate")!,
            apiKey: "sk-12345678",
            modelName: "model"
        )

        let report = OpenAIWireProtocolAuditor.auditConfiguration(config)
        #expect(report.passed) // Non-fatal
        #expect(report.score == 90.0)
        #expect(report.violations.contains { $0.code == "NON_STANDARD_ENDPOINT_PATH" })
    }

    @Test("SSE parser extracts text delta, reasoning delta, and [DONE] termination")
    func sseChunkParsing() {
        let textChunk = #"data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Swift 6.4"}}]}"#
        let (content, reasoning, isDone) = OpenAIWireProtocolAuditor.parseSSEChunk(textChunk)
        #expect(content == "Swift 6.4")
        #expect(reasoning == nil)
        #expect(!isDone)

        let reasoningChunk = #"data: {"id":"chatcmpl-2","choices":[{"delta":{"reasoning_content":"Step 1: Check types."}}]}"#
        let (content2, reasoning2, isDone2) = OpenAIWireProtocolAuditor.parseSSEChunk(reasoningChunk)
        #expect(content2 == nil)
        #expect(reasoning2 == "Step 1: Check types.")
        #expect(!isDone2)

        let doneChunk = "data: [DONE]"
        let (content3, reasoning3, isDone3) = OpenAIWireProtocolAuditor.parseSSEChunk(doneChunk)
        #expect(content3 == nil)
        #expect(reasoning3 == nil)
        #expect(isDone3)

        let commentChunk = ": ping keepalive"
        let (content4, reasoning4, isDone4) = OpenAIWireProtocolAuditor.parseSSEChunk(commentChunk)
        #expect(content4 == nil)
        #expect(reasoning4 == nil)
        #expect(!isDone4)
    }

    @Test("ModelProvider parses third-party provider names cleanly")
    func modelProviderParsing() {
        #expect(ModelProvider.parse("openai") == .openAICompatible)
        #expect(ModelProvider.parse("groq") == .openAICompatible)
        #expect(ModelProvider.parse("deepseek") == .openAICompatible)
        #expect(ModelProvider.parse("openrouter") == .openAICompatible)
        #expect(!ModelProvider.openAICompatible.isLocal)
        #expect(ModelProvider.openAICompatible.badge == "🌐 OpenAI")
    }

    @Test("formatOpenAIConfigurationMarkdown outputs valid markdown table")
    func markdownTelemetryFormatting() {
        let model = OpenAICompatibleLanguageModel(
            endpointURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            apiKey: "gsk_1234567890abcdef",
            modelName: "llama-3.3-70b-versatile"
        )
        let md = model.formatOpenAIConfigurationMarkdown()
        #expect(md.contains("Universal OpenAI-Compatible Model Telemetry"))
        #expect(md.contains("api.groq.com"))
        #expect(md.contains("llama-3.3-70b-versatile"))
    }
}
