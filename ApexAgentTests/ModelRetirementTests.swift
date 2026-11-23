//
//  ModelRetirementTests.swift
//  ApexAgentTests
//
//  Issue #180: Model retirement handling: auto-swap, warn, and keep working when a model disappears.
//

import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Issue #180: Model Retirement Handling Tests

@Suite("Issue #180 — Model Retirement Handling Tests")
struct ModelRetirementTests {

    @Test("Retired model is detected at startup, flagged, and auto-swapped before any task runs")
    func testStartupDetectionAndAutoSwap() {
        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        router.clearDailyLimits()
        router.resetRules()
        retirementManager.clearHistory()
        retirementManager.clearNotices()
        retirementManager.resetToDefaults()
        defer {
            retirementManager.resetToDefaults()
            router.resetRules()
        }

        let spaceId = UUID()
        let retiredModelId = "copilot-gpt-4-0613"

        // Register immediate retirement
        let record = ModelRetirementRecord(
            modelId: retiredModelId,
            displayName: "GitHub Copilot GPT-4 (0613)",
            retirementDate: Date().addingTimeInterval(-3600),
            reason: "GitHub Copilot model version 0613 retired on Dec 14, 2026",
            suggestedReplacementId: "localOllama"
        )
        retirementManager.registerRetirement(record)

        // Space initially configured with the retired model
        let initialRule = TaskRoutingRule(
            spaceId: spaceId,
            taskKind: .coding,
            preferredModelId: retiredModelId
        )
        router.setRule(initialRule, for: spaceId)

        // Run startup scan
        let notices = router.detectAndSwapRetiredModels(spaceIds: [spaceId], atStartup: true)
        #expect(!notices.isEmpty, "Startup scan must emit a notice for retired model")

        guard let notice = notices.first else {
            Issue.record("Expected startup notice")
            return
        }

        #expect(notice.oldModelId == retiredModelId, "Notice must name the retired model")
        #expect(notice.newModelId == "localOllama", "Notice must name the replacement model")
        #expect(notice.reason.contains("retired on Dec 14, 2026"), "Notice must state retirement reason")
        #expect(notice.message.contains(retiredModelId), "Notice message must contain old model ID")
        #expect(notice.message.contains("localOllama"), "Notice message must contain replacement model ID")

        // Invariant: Space rule is auto-swapped to replacement before any task runs
        let updatedRules = router.rules(for: spaceId)
        let activeCodingPreferred = updatedRules.first(where: { $0.taskKind == .coding })?.preferredModelId
        #expect(activeCodingPreferred == "localOllama", "Space rule preferred model must be auto-swapped to 'localOllama'")
    }

    @Test("Runtime model retirement triggers auto-swap with visible notice naming old model, new model, and reason")
    func testRuntimeRetirementTriggersAutoSwapWithNotice() {
        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        router.clearDailyLimits()
        router.resetRules()
        retirementManager.clearHistory()
        retirementManager.clearNotices()
        defer {
            retirementManager.resetToDefaults()
            router.resetRules()
        }

        let spaceId = UUID()
        let runtimeModelId = "copilot-claude-3-haiku"

        // Configure Space with model before retirement
        let rule = TaskRoutingRule(
            spaceId: spaceId,
            taskKind: .classification,
            preferredModelId: runtimeModelId
        )
        router.setRule(rule, for: spaceId)

        // Simulate runtime retirement
        let retirementReason = "Provider retired Claude 3 Haiku API endpoint"
        let record = ModelRetirementRecord(
            modelId: runtimeModelId,
            displayName: "GitHub Copilot Claude 3 Haiku",
            retirementDate: Date().addingTimeInterval(-60),
            reason: retirementReason,
            suggestedReplacementId: "appleOnDevice"
        )
        retirementManager.registerRetirement(record)

        // Route a classification task
        let routeResult = router.route(taskKind: .classification, spaceId: spaceId)
        #expect(routeResult.isSuccess, "Route result must succeed via auto-swap")

        guard let decision = routeResult.decision else {
            Issue.record("Expected routing decision after auto-swap")
            return
        }

        #expect(decision.selectedModelId == "appleOnDevice", "Must auto-swap to nearest capable free replacement 'appleOnDevice'")
        #expect(decision.isFree, "Replacement must be free-tier")
        #expect(decision.estimatedCost == 0.0, "Cost must be zero")

        guard let notice = decision.fallbackNotice else {
            Issue.record("Decision must carry user-visible fallback notice")
            return
        }

        #expect(notice.contains(runtimeModelId), "Notice must explicitly name the old model")
        #expect(notice.contains(decision.selectedModelId), "Notice must explicitly name the new replacement model")
        #expect(notice.contains(retirementReason), "Notice must explain why the model changed")
        #expect(decision.reason.contains("Fallback from retired"), "Decision reason must log retirement fallback trigger")
    }

    @Test("After retirement auto-swap, all Spaces point to active models and no Space is left pointing at a dead model")
    func testNoSpaceLeftPointingAtDeadModel() {
        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        router.clearDailyLimits()
        router.resetRules()
        defer {
            retirementManager.resetToDefaults()
            router.resetRules()
        }

        let spaceA = UUID()
        let spaceB = UUID()

        let retiredA = "copilot-gpt-4-0613"
        let retiredB = "gemini-1.0-pro"

        retirementManager.registerRetirement(ModelRetirementRecord(
            modelId: retiredA,
            displayName: "Copilot GPT-4 (0613)",
            retirementDate: Date().addingTimeInterval(-100),
            reason: "Deprecated model version"
        ))
        retirementManager.registerRetirement(ModelRetirementRecord(
            modelId: retiredB,
            displayName: "Gemini 1.0 Pro",
            retirementDate: Date().addingTimeInterval(-100),
            reason: "Deprecated API tier"
        ))

        router.setRule(TaskRoutingRule(spaceId: spaceA, taskKind: .coding, preferredModelId: retiredA), for: spaceA)
        router.setRule(TaskRoutingRule(spaceId: spaceB, taskKind: .classification, preferredModelId: retiredB), for: spaceB)

        // Trigger detection and swap across both Spaces
        _ = router.detectAndSwapRetiredModels(spaceIds: [spaceA, spaceB], atStartup: true)

        let rulesA = router.rules(for: spaceA)
        let rulesB = router.rules(for: spaceB)

        for rule in rulesA + rulesB {
            if let pid = rule.preferredModelId {
                let isDead = retirementManager.isRetired(modelId: pid)
                #expect(!isDead, "No Space rule must point to retired model '\(pid)'")
            }
        }

        #expect(rulesA.first?.preferredModelId == "localOllama")
        #expect(rulesB.first?.preferredModelId == "appleOnDevice")
    }

    @Test("When no capable free replacement exists, app plainly explains and offers next cheapest paid option without silently selecting it ($0 spend)")
    func testGracefulDegradationWithoutSilentPaidSelection() {
        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        router.clearDailyLimits()
        router.resetRules()

        let spaceId = UUID()
        let multimodalKind = ModelTaskKind.multimodal

        // Multimodal free models are cloudGemini and localOllama.
        // Retire both to simulate exhaustion of all free alternatives for multimodal.
        let recGemini = ModelRetirementRecord(
            modelId: "cloudGemini",
            displayName: "Google Gemini Cloud",
            retirementDate: Date().addingTimeInterval(-30),
            reason: "Provider cloud tier retired"
        )
        let recOllama = ModelRetirementRecord(
            modelId: "localOllama",
            displayName: "Local Ollama",
            retirementDate: Date().addingTimeInterval(-30),
            reason: "Vision weights unavailable"
        )
        retirementManager.registerRetirement(recGemini)
        retirementManager.registerRetirement(recOllama)

        let result = router.route(taskKind: multimodalKind, spaceId: spaceId)

        // Restore immediately after test invocation
        retirementManager.unregisterRetirement(modelId: "cloudGemini")
        retirementManager.unregisterRetirement(modelId: "localOllama")

        switch result {
        case .fallbackExhausted(let reason):
            #expect(reason.contains("No capable free replacement exists") || reason.contains("retired"), "Message must explain absence of free replacement")
            #expect(reason.contains("Next cheapest available option"), "Message must offer cheapest available paid option")
            #expect(reason.contains("Zero-spend guarantee"), "Must assert zero-spend guarantee")
            #expect(!reason.contains("Silently selecting paid model"), "Must never silently select a paid model")
        case .routed(let decision):
            Issue.record("CRITICAL: Must not silently select paid model [\(decision.selectedModelId)] without user approval")
        case .paidEscalationRefused(let reason, _):
            #expect(reason.contains("Refusing paid escalation"), "Must refuse unapproved paid escalation")
        }
    }

    @Test("Per-Space model history records swaps, prevents reverting to retired models, and allows reverting to available models")
    func testPerSpaceSwapHistoryAndRevertInvariants() async {
        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        router.clearDailyLimits()
        router.resetRules()
        retirementManager.clearHistory()
        retirementManager.clearNotices()
        retirementManager.resetToDefaults()

        let spaceId = UUID()

        // 1. Record a swap between two operational free models
        retirementManager.recordSwap(
            spaceId: spaceId,
            oldModelId: "localOllama",
            newModelId: "localMLX",
            reason: "User configured Metal acceleration"
        )

        let history = retirementManager.history(for: spaceId)
        #expect(history.count == 1, "History must contain exactly 1 swap")
        guard let swap = history.first else {
            Issue.record("Expected swap record in history")
            return
        }

        #expect(swap.oldModelId == "localOllama")
        #expect(swap.newModelId == "localMLX")
        #expect(swap.reason == "User configured Metal acceleration")

        // 2. Revert to available model ('localOllama') succeeds
        do {
            let revertMsg = try retirementManager.revert(swapId: swap.id, in: spaceId, router: router)
            #expect(revertMsg.contains("Successfully reverted Space to 'localOllama'"))
            let currentRules = router.rules(for: spaceId)
            #expect(currentRules.first?.preferredModelId == "localOllama", "Revert must restore preferredModelId in ModelRouter")
        } catch {
            Issue.record("Revert to available model should not throw: \(error)")
        }

        // 3. Attempting to revert to a model that is retired must be blocked
        let retiredSwapRecord = SpaceModelSwapRecord(
            spaceId: spaceId,
            oldModelId: "copilot-gpt-4-0613",
            newModelId: "localOllama",
            reason: "Auto-swap after retirement"
        )
        retirementManager.recordSwap(
            spaceId: spaceId,
            oldModelId: retiredSwapRecord.oldModelId,
            newModelId: retiredSwapRecord.newModelId,
            reason: retiredSwapRecord.reason
        )

        // Mark 'copilot-gpt-4-0613' as retired
        retirementManager.registerRetirement(ModelRetirementRecord(
            modelId: "copilot-gpt-4-0613",
            displayName: "Copilot GPT-4",
            retirementDate: Date().addingTimeInterval(-100),
            reason: "Model version retired by GitHub"
        ))

        let lastSwapId = retirementManager.history(for: spaceId).last!.id
        var blockedErrorThrown = false
        do {
            _ = try retirementManager.revert(swapId: lastSwapId, in: spaceId, router: router)
            Issue.record("Reverting to a retired model must throw an error")
        } catch let ModelRetirementError.cannotRevertToRetiredModel(modelId, reason) {
            #expect(modelId == "copilot-gpt-4-0613")
            #expect(reason.contains("retired by GitHub"))
            blockedErrorThrown = true
        } catch {
            Issue.record("Unexpected error thrown: \(error)")
        }
        #expect(blockedErrorThrown, "Must throw cannotRevertToRetiredModel when old model is retired")

        // Run full live verification suite to ensure all 6 verdicts pass
        let liveLogPath = "/Users/danielstevens/.gemini/antigravity/worktrees/ApexAgent/issue180_model_retirement/runs/issue180/live-verify-round1.log"
        let liveResult = await ModelRetirementLiveVerifier.runVerification(logPath: liveLogPath)
        defer {
            retirementManager.resetToDefaults()
            router.resetRules()
            router.clearDailyLimits()
            retirementManager.clearHistory()
            retirementManager.clearNotices()
        }
        #expect(liveResult.passed, "All 6 live verifier checks must pass:\n\(liveResult.output)")
        #expect(liveResult.totalChecks == 6)
        #expect(liveResult.passedChecks == 6)
    }
}
