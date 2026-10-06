import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

@Suite("ModelCapacityRoutingTests")
struct ModelCapacityRoutingTests {
    @Test("Token count estimation accurately measures prompt size")
    func testTokenCountEstimation() {
        let shortPrompt = "What is 2 + 2?"
        let tokens = ModelRegistry.estimateTokenCount(prompt: shortPrompt)
        #expect(tokens < 100)

        let largeText = String(repeating: "Large prompt content for agent task analysis. ", count: 500)
        let largeTokens = ModelRegistry.estimateTokenCount(prompt: largeText)
        #expect(largeTokens > 4000)
    }

    @Test("Small task stays on Apple On-Device")
    func testSmallTaskStaysOnDevice() {
        let prompt = "Explain recursion in Swift."
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: prompt,
            isPCCAvailable: true
        )
        #expect(provider == .appleOnDevice)
        #expect(reason == nil)
    }

    @Test("Task over 4k limit tiers to Apple Private Cloud Compute when available")
    func testLargeTaskTiersToPCC() {
        let largePrompt = String(repeating: "Full file contents and repository context. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: largePrompt,
            isPCCAvailable: true
        )
        #expect(provider == .applePCC)
        #expect(reason?.contains("Private Cloud Compute") == true)
    }

    @Test("Task over 4k limit tiers to Local Ollama gemma4:12bmlx when PCC unavailable")
    func testLargeTaskTiersToOllamaWhenPCCUnavailable() {
        let largePrompt = String(repeating: "Full file contents and repository context. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: largePrompt,
            isPCCAvailable: false
        )
        #expect(provider == .localOllama)
        #expect(reason?.contains("Local Ollama") == true)
    }

    @Test("Explicit model preference overrides automatic tiering")
    func testExplicitModelOverrideRespected() {
        let largePrompt = String(repeating: "Large repository code diff. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .localMLX,
            prompt: largePrompt,
            isPCCAvailable: true
        )
        #expect(provider == .localMLX)
        #expect(reason == nil)
    }
}
