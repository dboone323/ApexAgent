import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Issue #179: Model Router / Orchestrator Tests

@Suite("Issue #179 — Model Router & Free-Tier Orchestrator Tests")
struct ModelRouterTests {

    @Test("Light tasks (classification, routing, verification) route to free light models with zero cost")
    func testLightTaskRoutesToLightFreeModel() {
        let router = ModelRouter.shared
        router.clearDailyLimits()
        router.resetRules()

        // 1. Classification task
        let classResult = router.route(taskKind: .classification)
        #expect(classResult.isSuccess, "Classification task must route successfully")
        guard let classDec = classResult.decision else {
            Issue.record("Expected routing decision for classification")
            return
        }
        #expect(classDec.isFree, "Classification must route to a free model")
        #expect(classDec.estimatedCost == 0.0, "Classification cost must be strictly $0.0")
        #expect(classDec.selectedModelId == "appleOnDevice", "Classification must select on-device light model")

        // 2. Routing task
        let routeResult = router.route(taskKind: .routing)
        #expect(routeResult.isSuccess, "Routing task must route successfully")
        guard let routeDec = routeResult.decision else {
            Issue.record("Expected routing decision for routing")
            return
        }
        #expect(routeDec.isFree, "Routing task must route to a free model")
        #expect(routeDec.estimatedCost == 0.0, "Routing cost must be strictly $0.0")
        #expect(routeDec.selectedModelId == "appleOnDevice", "Routing must select on-device light model")
    }

    @Test("Heavy tasks (coding and reasoning) route to capable heavy models with zero cost")
    func testHeavyTaskRoutesToHeavyCapableModel() {
        let router = ModelRouter.shared
        router.clearDailyLimits()
        router.resetRules()

        // 1. Coding task
        let codingResult = router.route(taskKind: .coding)
        #expect(codingResult.isSuccess, "Coding task must route successfully")
        guard let codingDec = codingResult.decision else {
            Issue.record("Expected routing decision for coding")
            return
        }
        #expect(codingDec.isFree, "Coding task must route to a free model")
        #expect(codingDec.estimatedCost == 0.0, "Coding cost must be strictly $0.0")
        #expect(codingDec.selectedModelId == "localOllama", "Coding task must select local heavy model")

        // 2. Multimodal task (with attachments)
        let mmResult = router.route(taskKind: .coding, hasAttachments: true)
        #expect(mmResult.isSuccess, "Multimodal task must route successfully")
        guard let mmDec = mmResult.decision else {
            Issue.record("Expected routing decision for multimodal")
            return
        }
        #expect(mmDec.isFree, "Multimodal task must route to free tier")
        #expect(mmDec.estimatedCost == 0.0, "Multimodal cost must be strictly $0.0")
        #expect(mmDec.selectedModelId == "cloudGemini", "Multimodal task must select vision-capable model")
    }

    @Test("Simulating daily limit falls back cleanly to next capable free model with notice and no loop")
    func testLimitHitFallsBackToNextFreeModelWithNotificationAndNoLoop() {
        let router = ModelRouter.shared
        router.clearDailyLimits()
        router.resetRules()

        let primaryModel = "localOllama"
        router.recordDailyLimitHit(modelId: primaryModel, reason: "Daily free quota reached")
        #expect(router.isDailyLimitHit(modelId: primaryModel), "Daily limit should be registered")

        let result = router.route(taskKind: .coding)
        #expect(result.isSuccess, "Task must fall back to alternate capable free model")
        guard let fallbackDec = result.decision else {
            Issue.record("Expected fallback decision")
            return
        }

        #expect(fallbackDec.selectedModelId != primaryModel, "Must not route to limit-exhausted model")
        #expect(fallbackDec.isFree, "Fallback model must remain free tier")
        #expect(fallbackDec.estimatedCost == 0.0, "Fallback cost must be strictly $0.0")
        #expect(fallbackDec.fallbackNotice != nil, "Fallback notice must be surfaced")
        #expect(fallbackDec.fallbackNotice?.contains("hit daily limit") == true, "Notice must explain limit hit")

        // Ensure consecutive calls do not loop or retry the exhausted model
        let secondCall = router.route(taskKind: .coding)
        guard let secondDec = secondCall.decision else {
            Issue.record("Expected consistent fallback decision on second call")
            return
        }
        #expect(secondDec.selectedModelId != primaryModel, "Second call must still avoid exhausted model")
        #expect(secondDec.selectedModelId == fallbackDec.selectedModelId, "Second call must resolve deterministically")

        router.clearDailyLimits()
    }

    @Test("Paid escalation without explicit user approval is refused with zero cost incurred")
    func testPaidEscalationRefusedWithoutExplicitUserApproval() {
        let router = ModelRouter.shared
        router.clearDailyLimits()
        router.resetRules()

        // 1. Unapproved escalation to Claude
        let claudeResult = router.route(
            taskKind: .coding,
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: PaidEscalationApproval.refused
        )

        switch claudeResult {
        case .paidEscalationRefused(let reason, let costNote):
            #expect(!reason.isEmpty, "Refusal reason must be non-empty")
            #expect(!costNote.isEmpty, "Cost note must describe pricing")
            #expect(costNote.contains("Estimated cost"), "Cost note must display cost")
        case .routed(let decision):
            Issue.record("Paid model must NOT be routed without approval! Routed: \(decision.selectedModelId)")
        case .fallbackExhausted(let reason):
            Issue.record("Unexpected fallback exhausted: \(reason)")
        }

        // 2. Approved escalation works when explicitly granted
        let approvedResult = router.route(
            taskKind: .coding,
            preferredModelId: "anthropic-claude-3-5-sonnet",
            approval: PaidEscalationApproval(isApproved: true, userApprovalToken: "test-token-179", authorizedSpendCap: 1.0)
        )
        #expect(approvedResult.isSuccess, "Approved escalation should route to requested model")
        if let dec = approvedResult.decision {
            #expect(dec.selectedModelId == "anthropic-claude-3-5-sonnet")
            #expect(!dec.isFree)
            #expect(dec.estimatedCost > 0.0)
        }
    }

    @Test("Space routing rules can be viewed, edited, logged with cost and latency, and live verifier passes")
    func testSpaceRoutingRuleAndCostLatencyLoggingAndLiveVerifier() async {
        let router = ModelRouter.shared
        router.clearDailyLimits()
        router.resetRules()
        router.clearDecisions()

        let spaceId = UUID()
        let initialRules = router.rules(for: spaceId)
        #expect(initialRules.isEmpty, "Space should initially have no custom rules")

        // Edit Space rule: map classification to localOllama
        let customRule = TaskRoutingRule(
            spaceId: spaceId,
            taskKind: .classification,
            preferredModelId: "localOllama"
        )
        router.setRule(customRule, for: spaceId)

        let savedRules = router.rules(for: spaceId)
        #expect(savedRules.count == 1, "Space should have 1 custom rule")
        #expect(savedRules.first?.preferredModelId == "localOllama")

        // Route for Space
        let spaceResult = router.route(taskKind: .classification, spaceId: spaceId)
        guard let spaceDec = spaceResult.decision else {
            Issue.record("Expected routing decision for space")
            return
        }
        #expect(spaceDec.selectedModelId == "localOllama", "Space rule override must be respected")

        // Check global still routes to default
        let globalResult = router.route(taskKind: .classification)
        #expect(globalResult.decision?.selectedModelId == "appleOnDevice", "Global routing must remain un-affected")

        // Verify decision logging
        let decisions = router.recentDecisions()
        #expect(!decisions.isEmpty, "Routing decisions must be recorded")
        for dec in decisions {
            #expect(dec.latencyMs >= 0.0, "Latency must be non-negative")
            #expect(dec.isFree == (dec.estimatedCost == 0.0), "Free models must have $0.0 cost")
        }
        let formatted = router.formattedLog()
        #expect(formatted.contains("Selected Model"), "Formatted log must contain headers")

        // Run the real LiveVerifier to confirm all 6 checks pass end-to-end
        let liveLogPath = "/Users/danielstevens/.gemini/antigravity/worktrees/ApexAgent/issue179_model_router/runs/issue179/live-verify-round1.log"
        let liveResult = await ModelRouterLiveVerifier.runVerification(logPath: liveLogPath)
        #expect(liveResult.passed, "All 6 live verifier checks must pass: \n\(liveResult.output)")
        #expect(liveResult.totalChecks == 6)
        #expect(liveResult.passedChecks == 6)
    }
}
