import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 63 — App Intents Schema & Siri Shortcuts Contract Integrity Auditor Tests")
struct AppIntentsContractAuditorTests {

    @Test("Canonical AppIntent descriptors pass audit with score 100.0")
    func canonicalIntentsPassAudit() {
        let report = AppIntentsContractAuditor.audit()
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.evaluatedIntentsCount == 6)
        #expect(report.violations.isEmpty)
    }

    @Test("Empty or whitespace title triggers critical violation")
    func emptyTitleTriggersCriticalViolation() {
        let bad = [
            AppIntentDescriptor(
                identifier: "BadIntent",
                title: "   ",
                summaryTemplate: "Bad intent summary",
                parameters: []
            )
        ]
        let report = AppIntentsContractAuditor.audit(descriptors: bad)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "INTENT-001" && $0.severity == .critical })
    }

    @Test("Missing parameter in summary template triggers medium violation")
    func missingParamInSummaryTriggersMediumViolation() {
        let desc = [
            AppIntentDescriptor(
                identifier: "SearchIntent",
                title: "Search Agent",
                summaryTemplate: "Search everything", // missing ${query}
                parameters: ["query"],
                maxInputLength: 1024
            )
        ]
        let report = AppIntentsContractAuditor.audit(descriptors: desc)
        #expect(report.passed) // passes since medium doesn't fail unless >= high or score < 80
        #expect(report.violations.contains { $0.ruleId == "INTENT-003" && $0.severity == .medium })
    }

    @Test("Negative or zero maxInputLength triggers high violation")
    func negativeInputLengthTriggersHighViolation() {
        let desc = [
            AppIntentDescriptor(
                identifier: "PromptIntent",
                title: "Send Prompt",
                summaryTemplate: "Send ${prompt}",
                parameters: ["prompt"],
                maxInputLength: 0
            )
        ]
        let report = AppIntentsContractAuditor.audit(descriptors: desc)
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "INTENT-004" && $0.severity == .high })
    }

    @Test("validateInputArgument detects length overflow and null bytes")
    func inputArgumentValidationDetectsViolations() {
        let clean = AppIntentsContractAuditor.validateInputArgument("Hello world", parameterName: "prompt", maxLength: 100)
        #expect(clean.isEmpty)

        let oversized = AppIntentsContractAuditor.validateInputArgument(String(repeating: "A", count: 200), parameterName: "prompt", maxLength: 100)
        #expect(oversized.contains { $0.ruleId == "INP-001" && $0.severity == .high })

        let nullByte = AppIntentsContractAuditor.validateInputArgument("malicious\0command", parameterName: "prompt", maxLength: 100)
        #expect(nullByte.contains { $0.ruleId == "INP-002" && $0.severity == .critical })
    }

    @Test("Audit report encodes to valid JSON")
    func auditReportEncodesToJSON() {
        let report = AppIntentsContractAuditor.audit()
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
        #expect(json.contains("\"evaluatedIntentsCount\" : 6"))
    }
}
