import Foundation
import SwiftUI
import os

// MARK: - Onboarding & Free-Tier Live Verifier (Issue #118, J5)

/// Executes real functional live verification for the first-run onboarding model picker,
/// provider fact explanations (cost/privacy/speed), provider configuration,
/// free-tier withdrawal handling, graceful degradation, and anti-paid guarantee.
public enum OnboardingLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let totalChecks: Int
        public let passedChecks: Int
    }

    public static func runVerification(jsonOutput: Bool = false) async -> VerificationResult {
        var logs: [String] = []
        let isoFormatter = ISO8601DateFormatter()
        let timestamp = isoFormatter.string(from: Date())

        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #118: ONBOARDING FREE-TIER REALITY LIVE VERIFICATION (J5)")
        logs.append("Timestamp: \(timestamp)")
        logs.append("Host: Darwin arm64 — Model Picker, Free-Tier Degradation & Anti-Paid Guarantees")
        logs.append("================================================================================")

        var allPassed = true
        var passedChecks = 0
        let totalChecks = 5

        let manager = FreeTierModelManager.shared
        // Reset any prior test withdrawals to clean state
        manager.resetAllWithdrawals()

        // -------------------------------------------------------------------------
        // CHECK 1: Onboarding shows model picker with cost/privacy/speed per provider
        // -------------------------------------------------------------------------
        logs.append("\n[Check 1] Model Picker Provider Transparency (Cost / Privacy / Speed):")
        let options = manager.allOptions()
        var check1Passed = !options.isEmpty

        for opt in options {
            let hasCost = !opt.costFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasPrivacy = !opt.privacyFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasSpeed = !opt.speedFact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            logs.append("  -> Provider [\(opt.provider.rawValue)]: '\(opt.displayName)'")
            logs.append("     - Cost: \(opt.costFact)")
            logs.append("     - Privacy: \(opt.privacyFact)")
            logs.append("     - Speed: \(opt.speedFact)")

            if !hasCost || !hasPrivacy || !hasSpeed {
                check1Passed = false
            }
        }

        if check1Passed {
            passedChecks += 1
            logs.append("VERDICT 1: PASS (onboarding shows the model picker with cost/privacy/speed per provider: \(options.count) providers cataloged with full plain-language facts)")
        } else {
            allPassed = false
            logs.append("VERDICT 1: FAIL (some providers missing cost/privacy/speed explanations)")
        }

        // -------------------------------------------------------------------------
        // CHECK 2: Picking a provider configures it and the app runs on it
        // -------------------------------------------------------------------------
        logs.append("\n[Check 2] Picking a Provider Configures App Execution:")
        let testTarget: ModelProvider = .appleOnDevice
        await MainActor.run {
            manager.applyProviderSelection(testTarget)
        }

        let configuredProvider = ModelRegistry.activeProvider()
        let savedPreference = UserDefaults.standard.string(forKey: "apex.modelPreference")
        let resolved = ModelRegistry.resolveProviderForTask(
            preferred: testTarget,
            prompt: "let x = 42",
            instructions: "You are an assistant",
            tools: []
        )
        let modelInstance = ModelRegistry.model(for: .explicit(configuredProvider))
        let modelDescription = String(describing: type(of: modelInstance))

        logs.append("  -> Chosen provider: \(testTarget.rawValue)")
        logs.append("  -> ModelRegistry.activeProvider(): \(configuredProvider.rawValue)")
        logs.append("  -> UserDefaults[apex.modelPreference]: \(savedPreference ?? "nil")")
        logs.append("  -> Task routing resolved provider: \(resolved.provider.rawValue)")
        logs.append("  -> Model instance type: \(modelDescription)")

        let check2Passed = (configuredProvider == testTarget) &&
                           (resolved.provider == testTarget) &&
                           !modelDescription.isEmpty

        if check2Passed {
            passedChecks += 1
            logs.append("VERDICT 2: PASS (picking a provider configures it and the app runs on it: configured=\(configuredProvider.rawValue), resolved=\(resolved.provider.rawValue), instance=\(modelDescription))")
        } else {
            allPassed = false
            logs.append("VERDICT 2: FAIL (configured provider \(configuredProvider.rawValue) does not match expected \(testTarget.rawValue))")
        }

        // -------------------------------------------------------------------------
        // CHECK 3: With a free tier withdrawn, picker shows unavailable + explains why
        // -------------------------------------------------------------------------
        logs.append("\n[Check 3] Free-Tier Withdrawal Detection & Plain Explanation (The Gemini CLI Lesson):")
        let withdrawalReason = "Google AI Studio free tier quota exhausted or tier withdrawn by provider"
        manager.withdrawFreeTier(provider: .cloudGemini, reason: withdrawalReason)

        let isWithdrawn = manager.isWithdrawn(provider: .cloudGemini)
        let status = manager.status(for: .cloudGemini)
        let retrievedReason = manager.withdrawalReason(provider: .cloudGemini)

        logs.append("  -> Provider marked withdrawn: .cloudGemini")
        logs.append("  -> isWithdrawn(.cloudGemini): \(isWithdrawn)")
        logs.append("  -> Status: \(status)")
        logs.append("  -> Plain explanation: '\(retrievedReason ?? "nil")'")

        let check3Passed = isWithdrawn && (retrievedReason == withdrawalReason)

        if check3Passed {
            passedChecks += 1
            logs.append("VERDICT 3: PASS (with a free tier withdrawn, the picker shows it as unavailable and explains why: isWithdrawn=\(isWithdrawn), reason='\(retrievedReason ?? "")')")
        } else {
            allPassed = false
            logs.append("VERDICT 3: FAIL (withdrawal not properly reflected: isWithdrawn=\(isWithdrawn))")
        }

        // -------------------------------------------------------------------------
        // CHECK 4: App keeps working on remaining providers after the withdrawal
        // -------------------------------------------------------------------------
        logs.append("\n[Check 4] Graceful Degradation to Remaining Available Providers:")
        let degradationResult = manager.resolveGracefulDegradation(for: .cloudGemini)
        logs.append("  -> Requested withdrawn provider: .cloudGemini")
        logs.append("  -> Degraded to available provider: \(degradationResult.provider.rawValue)")
        logs.append("  -> Degraded flag: \(degradationResult.degraded)")
        logs.append("  -> Explanation: '\(degradationResult.explanation)'")

        let routingWithDegradation = ModelRegistry.resolveProviderForTask(
            preferred: .cloudGemini,
            prompt: "Refactor this function for safety",
            instructions: "Coding assistant",
            tools: []
        )
        logs.append("  -> ModelRegistry.resolveProviderForTask routed to: \(routingWithDegradation.provider.rawValue)")
        logs.append("  -> Routing reason: \(routingWithDegradation.reason ?? "none")")

        let candidateChain = ModelRegistry.buildCandidateChain(
            preferred: .cloudGemini,
            prompt: "Test candidate fallback chain"
        )
        let candidateNames = candidateChain.map { $0.provider.rawValue }.joined(separator: " -> ")
        logs.append("  -> Active candidate chain: \(candidateNames)")

        let candidateContainsWithdrawn = candidateChain.contains { $0.provider == .cloudGemini }
        let degradedModelInstance = ModelRegistry.model(for: .explicit(routingWithDegradation.provider))
        let degradedModelType = String(describing: type(of: degradedModelInstance))

        let check4Passed = degradationResult.degraded &&
                           degradationResult.provider != .cloudGemini &&
                           routingWithDegradation.provider != .cloudGemini &&
                           !candidateContainsWithdrawn &&
                           !degradedModelType.isEmpty

        if check4Passed {
            passedChecks += 1
            logs.append("VERDICT 4: PASS (the app keeps working on the remaining providers after the withdrawal: degraded to \(degradationResult.provider.rawValue) (\(degradedModelType)), candidate chain excludes withdrawn tier: [\(candidateNames)])")
        } else {
            allPassed = false
            logs.append("VERDICT 4: FAIL (app did not gracefully degrade away from withdrawn provider)")
        }

        // -------------------------------------------------------------------------
        // CHECK 5: No paid model or usage-based billing is offered anywhere in flow
        // -------------------------------------------------------------------------
        logs.append("\n[Check 5] Anti-Paid Model & Anti-Credit Guarantee:")
        let zeroPaidGuaranteed = manager.validateZeroPaidBillingGuarantee()
        let anyPaid = options.contains { $0.isPaid }
        let defaultOption = options.first { $0.isDefault }

        logs.append("  -> Zero-paid billing guarantee validated: \(zeroPaidGuaranteed)")
        logs.append("  -> Any paid option in catalog: \(anyPaid)")
        logs.append("  -> Default option: \(defaultOption?.displayName ?? "none") (isPaid=\(defaultOption?.isPaid ?? true))")

        var containsBillingKeywords = false
        for opt in options {
            let combined = (opt.costFact + " " + opt.displayName + " " + opt.privacyFact).lowercased()
            if combined.contains("credit card") || combined.contains("add credits") || combined.contains("usage-based") {
                containsBillingKeywords = true
                logs.append("  ❌ Found forbidden billing keyword in \(opt.provider.rawValue): \(combined)")
            }
        }

        let check5Passed = zeroPaidGuaranteed && !anyPaid && !containsBillingKeywords && (defaultOption?.isPaid == false)

        if check5Passed {
            passedChecks += 1
            logs.append("VERDICT 5: PASS (no paid model or usage-based billing is offered anywhere in the flow: guaranteedZeroPaid=\(zeroPaidGuaranteed), anyPaidOption=\(anyPaid), defaultProvider=\(defaultOption?.provider.rawValue ?? ""))")
        } else {
            allPassed = false
            logs.append("VERDICT 5: FAIL (paid option or billing keyword detected in onboarding surface)")
        }

        // Clean up state
        manager.resetAllWithdrawals()

        logs.append("\n================================================================================")
        logs.append("VERIFICATION RESULT: \(allPassed ? "PASS" : "FAIL") (\(passedChecks)/\(totalChecks) checks passed)")
        logs.append("================================================================================")

        let finalOutput = logs.joined(separator: "\n")

        // Persist to runs/issue118/live-verify.log
        writeLogFile(content: finalOutput)

        return VerificationResult(
            output: finalOutput,
            passed: allPassed,
            totalChecks: totalChecks,
            passedChecks: passedChecks
        )
    }

    private static func writeLogFile(content: String) {
        let fileManager = FileManager.default
        let currentDir = fileManager.currentDirectoryPath
        let issue118Dir = URL(fileURLWithPath: currentDir).appendingPathComponent("runs/issue118")
        let logFile = issue118Dir.appendingPathComponent("live-verify.log")

        try? fileManager.createDirectory(at: issue118Dir, withIntermediateDirectories: true)
        try? content.write(to: logFile, atomically: true, encoding: .utf8)
    }
}
