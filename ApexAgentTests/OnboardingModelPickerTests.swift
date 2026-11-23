import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Issue #118: Onboarding That Survives Free-Tier Reality (J5) Tests

@Suite("Issue #118 — Onboarding Free-Tier Reality & Model Picker Tests")
struct OnboardingModelPickerTests {

    @Test("Picker lists each provider with plain-language cost, privacy, and speed facts")
    func testPickerListsEachProviderWithCostPrivacySpeedFacts() {
        let manager = FreeTierModelManager.shared
        let options = manager.allOptions()

        #expect(!options.isEmpty, "Free-tier options catalog must not be empty")
        #expect(options.count >= 5, "Must catalog at least 5 free-tier / on-device providers")

        let expectedProviders: [ModelProvider] = [
            .autoPicker,
            .appleOnDevice,
            .localOllama,
            .applePCC,
            .cloudGemini,
            .localMLX
        ]

        for expected in expectedProviders {
            guard let opt = options.first(where: { $0.provider == expected }) else {
                Issue.record("Missing expected free-tier option: \(expected.rawValue)")
                continue
            }

            #expect(!opt.displayName.isEmpty, "Provider \(expected.rawValue) must have non-empty displayName")
            #expect(!opt.costFact.isEmpty, "Provider \(expected.rawValue) must have non-empty costFact")
            #expect(!opt.privacyFact.isEmpty, "Provider \(expected.rawValue) must have non-empty privacyFact")
            #expect(!opt.speedFact.isEmpty, "Provider \(expected.rawValue) must have non-empty speedFact")

            // Facts must be in plain language explaining zero cost / free tier
            let lowerCost = opt.costFact.lowercased()
            #expect(lowerCost.contains("free") || lowerCost.contains("$0"), "Cost fact must plainly state free/$0: \(opt.costFact)")

            // Privacy fact must explain data locality / encryption
            let lowerPrivacy = opt.privacyFact.lowercased()
            #expect(
                lowerPrivacy.contains("0 bytes") ||
                lowerPrivacy.contains("device") ||
                lowerPrivacy.contains("local") ||
                lowerPrivacy.contains("encrypted") ||
                lowerPrivacy.contains("cloud"),
                "Privacy fact must plainly describe data handling: \(opt.privacyFact)"
            )
        }
    }

    @Test("Picking a provider configures it and persists to app state")
    func testPickingProviderConfiguresItAndPersists() async {
        let manager = FreeTierModelManager.shared
        manager.resetAllWithdrawals()

        let target: ModelProvider = .appleOnDevice
        await MainActor.run {
            manager.applyProviderSelection(target)
        }

        #expect(ModelRegistry.activeProvider() == target, "ModelRegistry active provider should be configured")

        let savedPreference = UserDefaults.standard.string(forKey: "apex.modelPreference")
        #expect(savedPreference == AgentModelPreference.localSystem.rawValue, "UserDefaults apex.modelPreference must reflect localSystem")

        let resolved = ModelRegistry.resolveProviderForTask(
            preferred: target,
            prompt: "let message = \"Hello, ApexAgent\"",
            instructions: "You are a Swift assistant",
            tools: []
        )
        #expect(resolved.provider == target, "Task routing must resolve to configured provider")

        // Also test switching to localOllama
        let ollamaTarget: ModelProvider = .localOllama
        await MainActor.run {
            manager.applyProviderSelection(ollamaTarget)
        }
        #expect(ModelRegistry.activeProvider() == ollamaTarget)
        let savedOllamaPref = UserDefaults.standard.string(forKey: "apex.modelPreference")
        #expect(savedOllamaPref == AgentModelPreference.localOllama.rawValue)
    }

    @Test("Withdrawn free tier is shown as unavailable with a plain explanation")
    func testWithdrawnFreeTierShownAsUnavailableWithPlainExplanation() {
        let manager = FreeTierModelManager.shared
        manager.resetAllWithdrawals()

        let provider: ModelProvider = .cloudGemini
        let reason = "Google AI Studio free tier quota exhausted or tier withdrawn by provider"

        manager.withdrawFreeTier(provider: provider, reason: reason)

        #expect(manager.isWithdrawn(provider: provider), "Provider should be marked as withdrawn")
        let status = manager.status(for: provider)
        #expect(status == .withdrawn(reason: reason), "Status must report withdrawn with plain reason")
        #expect(manager.withdrawalReason(provider: provider) == reason, "Withdrawal reason must match verbatim")

        // Non-withdrawn provider should remain available
        #expect(!manager.isWithdrawn(provider: .appleOnDevice), "Apple On-Device must remain available")
        #expect(manager.status(for: .appleOnDevice) == .available)

        manager.resetAllWithdrawals()
    }

    @Test("Degradation keeps the app working on remaining available providers")
    func testDegradationKeepsAppWorkingOnRemainingProviders() {
        let manager = FreeTierModelManager.shared
        manager.resetAllWithdrawals()

        let withdrawnProvider: ModelProvider = .cloudGemini
        let reason = "Upstream provider discontinued free tier quota"
        manager.withdrawFreeTier(provider: withdrawnProvider, reason: reason)

        // 1. Degradation resolver must fall back to an available free provider
        let degradation = manager.resolveGracefulDegradation(for: withdrawnProvider)
        #expect(degradation.degraded, "Degraded flag must be true")
        #expect(degradation.provider != withdrawnProvider, "Degraded provider cannot be the withdrawn provider")
        #expect(degradation.provider == .appleOnDevice, "Default graceful degradation falls back to Apple on-device silicon")
        #expect(degradation.explanation.contains("withdrawn"), "Explanation must state that the tier was withdrawn")
        #expect(degradation.explanation.contains("Apple Intelligence") || degradation.explanation.contains("local"), "Explanation must name the degraded target")

        // 2. Task routing must not route to the withdrawn provider
        let routed = ModelRegistry.resolveProviderForTask(
            preferred: withdrawnProvider,
            prompt: "Test fallback routing prompt",
            instructions: "Swift coding assistant",
            tools: []
        )
        #expect(routed.provider != withdrawnProvider, "Model routing must not route to withdrawn provider")
        #expect(routed.provider == .appleOnDevice, "Model routing must degrade to Apple On-Device")
        #expect(routed.reason?.contains("withdrawn") == true, "Routing reason must note graceful degradation")

        // 3. Fallback candidate chain must exclude the withdrawn provider
        let candidates = ModelRegistry.buildCandidateChain(
            preferred: withdrawnProvider,
            prompt: "Fallback candidate chain verification"
        )
        #expect(!candidates.contains { $0.provider == withdrawnProvider }, "Candidate chain must exclude withdrawn provider")
        #expect(!candidates.isEmpty, "Candidate chain must contain remaining available providers")

        manager.resetAllWithdrawals()
    }

    @Test("No paid option is ever presented as default or the only path")
    func testNoPaidOptionPresentedAsDefaultOrOnlyPath() {
        let manager = FreeTierModelManager.shared
        let options = manager.allOptions()

        // 1. Anti-paid guarantee validation
        #expect(manager.validateZeroPaidBillingGuarantee(), "Anti-paid billing guarantee must pass")

        // 2. Every option must be isPaid == false
        for opt in options {
            #expect(!opt.isPaid, "Option '\(opt.displayName)' must not be flagged as paid")
            let lowerCost = opt.costFact.lowercased()
            #expect(!lowerCost.contains("credit card"), "Option '\(opt.displayName)' must not require credit card")
            #expect(!lowerCost.contains("usage-based"), "Option '\(opt.displayName)' must not require usage-based billing")
            #expect(!lowerCost.contains("add credits"), "Option '\(opt.displayName)' must not offer Add Credits")
        }

        // 3. Default option must be 100% free local or auto
        let defaultOptions = options.filter { $0.isDefault }
        #expect(defaultOptions.count == 1, "Must have exactly one default option")
        if let def = defaultOptions.first {
            #expect(!def.isPaid, "Default option must be free")
            #expect(def.provider == .autoPicker || def.provider == .appleOnDevice, "Default must be Auto or Apple on-device")
        }
    }

    @Test("Reinstating a withdrawn provider restores its availability")
    func testReinstatingWithdrawnProviderRestoresAvailability() {
        let manager = FreeTierModelManager.shared
        manager.resetAllWithdrawals()

        manager.withdrawFreeTier(provider: .cloudGemini, reason: "Temporary outage")
        #expect(manager.isWithdrawn(provider: .cloudGemini))

        manager.reinstateFreeTier(provider: .cloudGemini)
        #expect(!manager.isWithdrawn(provider: .cloudGemini), "Provider must no longer be marked withdrawn after reinstatement")
        #expect(manager.status(for: .cloudGemini) == .available)

        manager.resetAllWithdrawals()
    }

    @Test("Onboarding Live Verifier runs and passes all 5 checks with verdicts")
    func testOnboardingLiveVerifierAllFiveChecksPass() async {
        let result = await OnboardingLiveVerifier.runVerification()

        #expect(result.passed, "Onboarding live verifier must pass: \(result.output)")
        #expect(result.passedChecks == 5, "All 5 checks must pass")
        #expect(result.totalChecks == 5, "Total checks must be 5")

        #expect(result.output.contains("VERDICT 1: PASS"), "Must contain VERDICT 1: PASS")
        #expect(result.output.contains("VERDICT 2: PASS"), "Must contain VERDICT 2: PASS")
        #expect(result.output.contains("VERDICT 3: PASS"), "Must contain VERDICT 3: PASS")
        #expect(result.output.contains("VERDICT 4: PASS"), "Must contain VERDICT 4: PASS")
        #expect(result.output.contains("VERDICT 5: PASS"), "Must contain VERDICT 5: PASS")
    }
}
