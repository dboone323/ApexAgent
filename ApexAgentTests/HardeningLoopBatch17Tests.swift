import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch17Tests")
struct HardeningLoopBatch17Tests {
    @Test func testStrategyBadges() {
        #expect(AutoTieringStrategy.balanced.badge.contains("Balanced"))
        #expect(AutoTieringStrategy.cloudFirst.badge.contains("Performance"))
    }

    @Test func testProviderBadges() {
        #expect(ModelProvider.cloudGemini.badge.contains("Gemini"))
        #expect(ModelProvider.appleOnDevice.isLocal)
        #expect(ModelProvider.localOllama.isLocal)
        #expect(!ModelProvider.cloudGemini.isLocal)
        #expect(ModelProvider.cloudGemini.requiresNetwork)
        #expect(!ModelProvider.appleOnDevice.requiresNetwork)
    }

    @Test func testTierBadges() {
        #expect(ModelTier.reasoning.badge.contains("Reasoning"))
        #expect(ModelTier.fast.badge.contains("Fast"))
    }

    @Test func testPrivacyRanks() {
        #expect(PrivacyTier.strictlyOnDevice.privacyRank == 0)
        #expect(PrivacyTier.fullCloud.privacyRank == 3)
        #expect(PrivacyTier.strictlyOnDevice.satisfies(requirement: .fullCloud))
        #expect(!PrivacyTier.fullCloud.satisfies(requirement: .strictlyOnDevice))
        #expect(PrivacyTier.appleE2ECloud.satisfies(requirement: .appleE2ECloud))
    }

    @Test func testRoutingSummary() {
        let md = ModelRegistry.routingSummaryMarkdown()
        #expect(md.contains("Model Routing"))
    }

    @Test func testProviderParse() {
        #expect(ModelProvider.parse("gemini-2.5-flash") == .cloudGemini)
        #expect(ModelProvider.from(preference: "ollama") == .localOllama)
        #expect(ModelProvider.from(preference: "nonsense-xyz") == .autoPicker)
    }
}
