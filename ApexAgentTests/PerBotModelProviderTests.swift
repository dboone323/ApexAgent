import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - P0-1: Per-Bot Model Provider

@Suite("PerBotModelProviderTests")
struct PerBotModelProviderTests {

    @Test func botProfileDefaultsToNilProvider() {
        let bot = BotProfile(name: "TestBot")
        #expect(bot.modelProviderRaw == nil)
        #expect(bot.modelProvider == nil)
        #expect(bot.ollamaModelOverride == nil)
    }

    @Test func botProfileModelProviderRoundTrip() {
        let bot = BotProfile(name: "OllamaBot")
        bot.modelProvider = .localOllama
        #expect(bot.modelProviderRaw == "localOllama")
        #expect(bot.modelProvider == .localOllama)

        bot.modelProvider = .cloudGemini
        #expect(bot.modelProviderRaw == "cloudGemini")
        #expect(bot.modelProvider == .cloudGemini)

        bot.modelProvider = nil
        #expect(bot.modelProviderRaw == nil)
        #expect(bot.modelProvider == nil)
    }

    @Test func botProfileOllamaModelOverride() {
        let bot = BotProfile(name: "Coder")
        bot.modelProvider = .localOllama
        bot.ollamaModelOverride = "deepseek-r1:14b"
        #expect(bot.ollamaModelOverride == "deepseek-r1:14b")
    }

    @Test func modelRegistryEffectiveProviderUsesBotsOwnProvider() {
        let bot = BotProfile(name: "SpecialistBot")
        bot.modelProvider = .cloudGemini
        let effective = ModelRegistry.effectiveProvider(for: bot)
        #expect(effective == .cloudGemini)
    }

    @Test func modelRegistryEffectiveProviderFallsBackToGlobal() {
        let bot = BotProfile(name: "DefaultBot")
        // bot.modelProvider is nil → should use global
        let effective = ModelRegistry.effectiveProvider(for: bot)
        #expect(effective == ModelRegistry.activeProvider())
    }

    @Test func modelRegistryModelForBotReturnsCorrectType() {
        let bot = BotProfile(name: "OllamaBot")
        bot.modelProvider = .localOllama
        let model = ModelRegistry.model(for: bot)
        #expect(model is LocalOllamaLanguageModel)
    }

    @Test func modelRegistryModelForBotFallsBackToDefault() {
        let bot = BotProfile(name: "PlainBot")
        // modelProvider is nil → uses global activeProvider
        let model = ModelRegistry.model(for: bot)
        // Just verify it returns a model without crashing
        _ = model.capabilities
    }

    @Test func allModelProviderCasesHaveDisplayNames() {
        for provider in ModelProvider.allCases {
            #expect(!provider.displayName.isEmpty)
        }
    }
}
