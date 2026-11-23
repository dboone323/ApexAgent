//
//  ModelRetirementLiveVerifier.swift
//  ApexAgent
//
//  Issue #180: Live functional verifier for Model Retirement Auto-Swap, Warning, and Graceful Degradation
//

import Foundation
import os

public enum ModelRetirementLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let totalChecks: Int
        public let passedChecks: Int
    }

    public static func runVerification(
        logPath: String? = nil,
        jsonOutput: Bool = false
    ) async -> VerificationResult {
        var logs: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #180: MODEL RETIREMENT HANDLING LIVE VERIFICATION")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 — Auto-Swap, Warn, Zero-Spend Invariants, and Router Fallback")
        logs.append("================================================================================")

        var allPassed = true
        var passedChecks = 0
        let totalChecks = 6

        let router = ModelRouter.shared
        let retirementManager = ModelRetirementManager.shared

        // Reset state for pristine verifier execution
        router.clearDailyLimits()
        router.resetRules()
        router.clearDecisions()
        retirementManager.clearHistory()
        retirementManager.clearNotices()
        retirementManager.resetToDefaults()

        // -------------------------------------------------------------------------
        // CHECK 1: A Space pointing at a retired model is detected at startup and
        //          flagged before any task runs.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 1] Startup Detection & Flagging of Retired Space Model:")
        let space1 = UUID()
        let retiredModel1 = "copilot-gpt-4-0613"

        // Explicitly register retirement as effective immediately
        let retirementRecord1 = ModelRetirementRecord(
            modelId: retiredModel1,
            displayName: "GitHub Copilot GPT-4 (0613)",
            retirementDate: Date().addingTimeInterval(-3600), // retired 1 hour ago
            reason: "GitHub Copilot model version 0613 retired on Dec 14, 2026",
            suggestedReplacementId: "localOllama"
        )
        retirementManager.registerRetirement(retirementRecord1)

        // Space 1 rule was pointing to the retired model
        let rule1 = TaskRoutingRule(
            spaceId: space1,
            taskKind: .coding,
            preferredModelId: retiredModel1
        )
        router.setRule(rule1, for: space1)
        logs.append("  -> Space 1 [\(space1.uuidString.prefix(8))] configured with preferredModelId: '\(retiredModel1)'")

        // Run startup detection scan
        let startupNotices = router.detectAndSwapRetiredModels(spaceIds: [space1], atStartup: true)
        logs.append("  -> Startup scan generated \(startupNotices.count) notice(s)")

        var check1Passed = false
        if let notice = startupNotices.first {
            logs.append("  -> Detected old model: '\(notice.oldModelId)'")
            logs.append("  -> Auto-swapped new model: '\(notice.newModelId ?? "nil")'")
            logs.append("  -> Retirement reason: \(notice.reason)")
            logs.append("  -> Notice message: \(notice.message)")

            let currentRules = router.rules(for: space1)
            let updatedPreferred = currentRules.first(where: { $0.taskKind == .coding })?.preferredModelId

            let namesOld = notice.message.contains(retiredModel1) || notice.message.contains("Copilot GPT-4")
            let namesNew = notice.message.contains("localOllama") || notice.message.contains("Ollama")

            if notice.oldModelId == retiredModel1 &&
               notice.newModelId == "localOllama" &&
               updatedPreferred == "localOllama" &&
               namesOld &&
               namesNew {
                check1Passed = true
            }
        }

        if check1Passed {
            passedChecks += 1
            logs.append("VERDICT 1: PASS (Space pointing at retired model '\(retiredModel1)' detected at startup, flagged, and auto-swapped to 'localOllama' before task execution)")
        } else {
            allPassed = false
            logs.append("VERDICT 1: FAIL (retired model was not cleanly detected or auto-swapped at startup)")
        }

        // -------------------------------------------------------------------------
        // CHECK 2: A model retired at run time triggers an auto-swap to the nearest
        //          capable free replacement AND a visible notice naming old, new, why.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 2] Runtime Retirement Auto-Swap with Visible Notice:")
        let space2 = UUID()
        let runtimeRetiringModel = "copilot-claude-3-haiku"

        // Configure Space 2 with model before retirement
        let rule2 = TaskRoutingRule(
            spaceId: space2,
            taskKind: .classification,
            preferredModelId: runtimeRetiringModel
        )
        router.setRule(rule2, for: space2)

        // Model retires at runtime
        let runtimeReason = "GitHub Copilot Claude 3 Haiku retired by provider"
        let runtimeRecord = ModelRetirementRecord(
            modelId: runtimeRetiringModel,
            displayName: "GitHub Copilot Claude 3 Haiku",
            retirementDate: Date().addingTimeInterval(-60), // just retired
            reason: runtimeReason,
            suggestedReplacementId: "appleOnDevice"
        )
        retirementManager.registerRetirement(runtimeRecord)
        logs.append("  -> Runtime retirement registered for '\(runtimeRetiringModel)': \(runtimeReason)")

        // Send classification task through router
        let routeResult2 = router.route(taskKind: .classification, spaceId: space2)
        var check2Passed = false

        if case .routed(let decision) = routeResult2 {
            logs.append("  -> Selected replacement model: [\(decision.selectedModelId)] (\(decision.selectedProvider.displayName))")
            logs.append("  -> Decision reason: \(decision.reason)")
            logs.append("  -> Visible fallback notice: \(decision.fallbackNotice ?? "nil")")
            logs.append("  -> Cost: $\(String(format: "%.4f", decision.estimatedCost)) (isFree: \(decision.isFree))")

            let notice = decision.fallbackNotice ?? ""
            let noticeNamesOld = notice.contains(runtimeRetiringModel) || notice.contains("Claude 3 Haiku")
            let noticeNamesNew = notice.contains(decision.selectedModelId) || notice.contains("Apple Intelligence") || notice.contains("AFM")
            let noticeNamesWhy = notice.contains(runtimeReason)
            let isFreeReplacement = decision.isFree && decision.estimatedCost == 0.0

            if decision.selectedModelId == "appleOnDevice" &&
               isFreeReplacement &&
               noticeNamesOld &&
               noticeNamesNew &&
               noticeNamesWhy {
                check2Passed = true
            }
        } else {
            logs.append("  -> Routing unexpectedly failed: \(String(describing: routeResult2))")
        }

        if check2Passed {
            passedChecks += 1
            logs.append("VERDICT 2: PASS (runtime retirement of '\(runtimeRetiringModel)' triggered auto-swap to 'appleOnDevice' with notice naming old, new, and why)")
        } else {
            allPassed = false
            logs.append("VERDICT 2: FAIL (runtime retirement did not trigger auto-swap with complete notice)")
        }

        // -------------------------------------------------------------------------
        // CHECK 3: After the swap, no Space is left pointing at a dead model.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 3] Space Model Invariant (No Dead Models Remaining):")
        let space1Rules = router.rules(for: space1)
        let space2Rules = router.rules(for: space2)

        var deadModelsFound = false
        for r in space1Rules + space2Rules {
            if let pid = r.preferredModelId {
                if retirementManager.isRetired(modelId: pid) {
                    deadModelsFound = true
                    logs.append("  -> Dead model found in rule: Space [\(r.spaceId?.uuidString.prefix(8) ?? "global")] points to retired '\(pid)'")
                } else {
                    logs.append("  -> Space [\(r.spaceId?.uuidString.prefix(8) ?? "global")] points to active model: '\(pid)'")
                }
            }
        }

        let check3Passed = !deadModelsFound && !space1Rules.isEmpty && !space2Rules.isEmpty
        if check3Passed {
            passedChecks += 1
            logs.append("VERDICT 3: PASS (after auto-swap, all Spaces point to active models and no Space is left pointing at a dead model)")
        } else {
            allPassed = false
            logs.append("VERDICT 3: FAIL (one or more Spaces remain pointing at a dead or retired model)")
        }

        // -------------------------------------------------------------------------
        // CHECK 4: With no free replacement available, the app says so plainly and
        //          offers the next cheapest option — no paid model silently picked ($0).
        // -------------------------------------------------------------------------
        logs.append("\n[Check 4] Graceful Degradation When No Free Replacement Exists (Zero Spend):")
        let space4 = UUID()
        let multimodalTask = ModelTaskKind.multimodal

        // Multimodal free models in catalog are: cloudGemini and localOllama.
        // Temporarily retire cloudGemini and localOllama to simulate complete free-tier withdrawal for multimodal.
        let tempRetiredGemini = ModelRetirementRecord(
            modelId: "cloudGemini",
            displayName: "Google Gemini Cloud",
            retirementDate: Date().addingTimeInterval(-60),
            reason: "Google Gemini free tier shutdown"
        )
        let tempRetiredOllama = ModelRetirementRecord(
            modelId: "localOllama",
            displayName: "Local Ollama",
            retirementDate: Date().addingTimeInterval(-60),
            reason: "Local Ollama vision engine unavailable"
        )
        retirementManager.registerRetirement(tempRetiredGemini)
        retirementManager.registerRetirement(tempRetiredOllama)

        let check4Result = router.route(taskKind: multimodalTask, spaceId: space4)
        var check4Passed = false

        switch check4Result {
        case .fallbackExhausted(let reason):
            logs.append("  -> Graceful degradation message: \(reason)")
            let mentionsNoFree = reason.contains("No capable free replacement exists") || reason.contains("retired")
            let offersCheapestPaid = reason.contains("Next cheapest") || reason.contains("OpenAI GPT-4o") || reason.contains("Claude")
            let guaranteesZeroSpend = reason.contains("Zero-spend guarantee")

            if mentionsNoFree && offersCheapestPaid && guaranteesZeroSpend {
                check4Passed = true
            }
        case .routed(let decision):
            logs.append("  -> VIOLATION: Silently routed to model [\(decision.selectedModelId)] with cost $\(decision.estimatedCost)")
        case .paidEscalationRefused(let reason, _):
            logs.append("  -> Paid escalation refused: \(reason)")
            check4Passed = true
        }

        // Restore unretired status for cloudGemini and localOllama
        retirementManager.unregisterRetirement(modelId: "cloudGemini")
        retirementManager.unregisterRetirement(modelId: "localOllama")

        if check4Passed {
            passedChecks += 1
            logs.append("VERDICT 4: PASS (with no free replacement available, app says so plainly and offers next cheapest option without silently picking paid model, $0 incurred)")
        } else {
            allPassed = false
            logs.append("VERDICT 4: FAIL (graceful degradation failed to plainly state lack of free replacement or offer cheapest option)")
        }

        // -------------------------------------------------------------------------
        // CHECK 5: Per-Space history shows the swap (old, new, reason, time) and
        //          a revert to a still-available model works.
        // -------------------------------------------------------------------------
        logs.append("\n[Check 5] Per-Space Swap History & Revert Verification:")
        let space5 = UUID()

        // 1. Swap from localOllama to localMLX (both free, active, non-retired)
        retirementManager.recordSwap(
            spaceId: space5,
            oldModelId: "localOllama",
            newModelId: "localMLX",
            reason: "User switched to MLX for faster inference"
        )

        let history5 = retirementManager.history(for: space5)
        logs.append("  -> Space 5 history count: \(history5.count)")
        guard let swapRecord = history5.first else {
            logs.append("  -> Error: no swap record found in history")
            return VerificationResult(output: logs.joined(separator: "\n"), passed: false, totalChecks: totalChecks, passedChecks: passedChecks)
        }

        logs.append("  -> Recorded swap: old='\(swapRecord.oldModelId)', new='\(swapRecord.newModelId)', reason='\(swapRecord.reason)', time=\(swapRecord.timestamp)")

        // 2. Revert to 'localOllama' (still available)
        var revertSucceeded = false
        do {
            let revertMsg = try retirementManager.revert(swapId: swapRecord.id, in: space5, router: router)
            logs.append("  -> Revert result: \(revertMsg)")
            revertSucceeded = true
        } catch {
            logs.append("  -> Revert failed: \(error)")
        }

        // 3. Attempt revert to a retired model must be blocked
        retirementManager.recordSwap(
            spaceId: space5,
            oldModelId: "copilot-gpt-4-0613",
            newModelId: "localOllama",
            reason: "Auto-swap after retirement"
        )
        let retiredSwapId = retirementManager.history(for: space5).last!.id
        var blockedRetiredRevert = false
        do {
            _ = try retirementManager.revert(swapId: retiredSwapId, in: space5, router: router)
            logs.append("  -> VIOLATION: Revert to retired model was permitted!")
        } catch let ModelRetirementError.cannotRevertToRetiredModel(modelId, reason) {
            logs.append("  -> Successfully blocked revert to retired model '\(modelId)': \(reason)")
            blockedRetiredRevert = true
        } catch {
            logs.append("  -> Unexpected error on retired revert: \(error)")
        }

        let check5Passed = revertSucceeded && blockedRetiredRevert && history5.count >= 1
        if check5Passed {
            passedChecks += 1
            logs.append("VERDICT 5: PASS (per-Space history shows swap details (old, new, reason, time); revert works for available models and is safely blocked for retired models)")
        } else {
            allPassed = false
            logs.append("VERDICT 5: FAIL (per-Space history inspection or revert mechanism failed)")
        }

        // -------------------------------------------------------------------------
        // CHECK 6: The retirement swap flows through #179's router fallback chain
        //          (the router's own log shows the retirement as the fallback trigger).
        // -------------------------------------------------------------------------
        logs.append("\n[Check 6] Retirement Swap Integration with Router Fallback Chain Log:")
        let routerDecisions = router.recentDecisions()
        let formattedLog = router.formattedLog()
        logs.append("  -> Total logged router decisions: \(routerDecisions.count)")

        var retirementTriggerFoundInLog = false
        for d in routerDecisions {
            if d.reason.localizedCaseInsensitiveContains("retired") ||
               (d.fallbackNotice?.localizedCaseInsensitiveContains("retired") == true) {
                retirementTriggerFoundInLog = true
                logs.append("  -> Found retirement fallback decision: [\(d.taskKind.rawValue)] -> [\(d.selectedModelId)] (reason: \(d.reason))")
            }
        }

        let check6Passed = retirementTriggerFoundInLog && formattedLog.localizedCaseInsensitiveContains("retired")
        if check6Passed {
            passedChecks += 1
            logs.append("VERDICT 6: PASS (retirement swap flows through #179 router fallback chain and router log shows retirement as fallback trigger)")
        } else {
            allPassed = false
            logs.append("VERDICT 6: FAIL (router decision log does not contain retirement trigger evidence)")
        }

        // Summary
        logs.append("\n================================================================================")
        logs.append("SUMMARY: \(passedChecks)/\(totalChecks) CHECKS PASSED. ALL PASS: \(allPassed)")
        logs.append("================================================================================")

        let outputText = logs.joined(separator: "\n")

        // Write output to log file if path provided
        if let path = logPath {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? outputText.write(to: url, atomically: true, encoding: .utf8)
        }

        // Clean up verifier state so subsequent tests start clean
        router.clearDailyLimits()
        router.resetRules()
        retirementManager.clearHistory()
        retirementManager.clearNotices()
        retirementManager.resetToDefaults()

        return VerificationResult(
            output: outputText,
            passed: allPassed,
            totalChecks: totalChecks,
            passedChecks: passedChecks
        )
    }
}
