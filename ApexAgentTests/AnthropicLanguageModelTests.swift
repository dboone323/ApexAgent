//
//  AnthropicLanguageModelTests.swift
//  ApexAgentTests
//
//  Created for Batch 102: Anthropic Claude Messages API Integration & Wire Auditor.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 102 — Anthropic Claude Language Model & Wire Protocol Tests")
struct AnthropicLanguageModelTests {

    @Test("Valid HTTPS configuration passes wire protocol security audit with high score")
    func testValidConfigurationPassesAudit() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "sk-ant-api03-samplevalidkey-production12345",
            modelName: "claude-3-7-sonnet-20250219",
            maxTokens: 4096,
            temperature: 0.7,
            anthropicVersion: "2023-06-01"
        )

        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)

        #expect(report.isCompliant)
        #expect(report.securityScore >= 0.95)
        #expect(report.violations.isEmpty)
        #expect(report.hasAPIKey)
        #expect(report.endpointURL == "https://api.anthropic.com/v1/messages")
        #expect(report.modelName == "claude-3-7-sonnet-20250219")
        #expect(report.maxTokens == 4096)
    }

    @Test("Insecure remote HTTP endpoint trips fatal security violation")
    func testInsecureRemoteHTTPTripsFatalViolation() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "http://api.anthropic.com/v1/messages")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-3-5-haiku-20241022",
            maxTokens: 2048
        )

        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_REMOTE_HTTP" && $0.isFatal }))
        #expect(report.securityScore < 0.6)
    }

    @Test("Localhost HTTP endpoint is permitted for local proxy development")
    func testLocalhostHTTPAllowed() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "http://127.0.0.1:8080/v1/messages")!,
            apiKey: "sk-ant-local-key",
            modelName: "claude-3-5-sonnet-20241022",
            maxTokens: 1024
        )

        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)

        #expect(report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "LOCAL_HTTP_ALLOWED" && !$0.isFatal }))
    }

    @Test("Missing API key and zero max_tokens trip fatal violations")
    func testMissingKeyAndInvalidMaxTokens() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "",
            modelName: "claude-3-7-sonnet-20250219",
            maxTokens: 0,
            anthropicVersion: ""
        )

        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "MISSING_API_KEY" && $0.isFatal }))
        #expect(report.violations.contains(where: { $0.code == "INVALID_MAX_TOKENS" && $0.isFatal }))
        #expect(report.violations.contains(where: { $0.code == "MISSING_VERSION_HEADER" && $0.isFatal }))
    }

    @Test("Non-standard model name produces non-fatal warning")
    func testNonStandardModelName() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "sk-ant-valid-key",
            modelName: "my-custom-proxy-model",
            maxTokens: 2048
        )

        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)

        #expect(report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "NON_STANDARD_MODEL_NAME" && !$0.isFatal }))
    }

    @Test("Anthropic SSE parser extracts text delta and message_stop termination")
    func testAnthropicSSEParser() {
        let deltaLine = "data: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"Hello from Claude!\"}}"
        let deltaResult = AnthropicSSEParser.parseLine(deltaLine)
        #expect(deltaResult == .text("Hello from Claude!"))

        let stopLine = "data: {\"type\": \"message_stop\"}"
        let stopResult = AnthropicSSEParser.parseLine(stopLine)
        #expect(stopResult == .messageStop)

        let pingLine = "event: ping"
        #expect(AnthropicSSEParser.parseLine(pingLine) == nil)
    }

    @Test("ModelProvider parses anthropic and claude keywords cleanly")
    func testModelProviderParsing() {
        #expect(ModelProvider.parse("anthropic") == .anthropic)
        #expect(ModelProvider.parse("claude-3-7") == .anthropic)
        #expect(ModelProvider.parse("CLAUDE_SONNET") == .anthropic)
        #expect(ModelProvider.anthropic.displayName == "Anthropic Claude API")
        #expect(ModelProvider.anthropic.badge == "🎭 Claude")
        #expect(!ModelProvider.anthropic.isLocal)
        #expect(ModelProvider.anthropic.requiresNetwork)
    }

    @Test("formatAnthropicConfigurationMarkdown outputs valid markdown table")
    func testMarkdownFormatting() {
        let config = AnthropicModelConfiguration(
            endpointURL: URL(string: "https://api.anthropic.com/v1/messages")!,
            apiKey: "sk-ant-prod-key",
            modelName: "claude-3-7-sonnet-20250219",
            maxTokens: 8192
        )
        let report = AnthropicWireProtocolAuditor.auditConfiguration(config)
        let md = AnthropicWireProtocolAuditor.formatAnthropicConfigurationMarkdown(report)

        #expect(md.contains("### 🎭 Anthropic Messages Protocol & Security Audit"))
        #expect(md.contains("claude-3-7-sonnet-20250219"))
        #expect(md.contains("8192"))
        #expect(md.contains("2023-06-01"))
    }
}
