import Foundation
import AppIntents

// MARK: - App Intents Schema & Siri Shortcuts Contract Integrity Auditor (Batch 63)

/// Severity of an App Intents contract violation.
public enum IntentViolationSeverity: String, Codable, Sendable, Comparable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    private var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: IntentViolationSeverity, rhs: IntentViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific violation detected during App Intents contract auditing.
public struct AppIntentViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(intentName):\(ruleId):\(message)" }
    public let intentName: String
    public let ruleId: String
    public let severity: IntentViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        intentName: String,
        ruleId: String,
        severity: IntentViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.intentName = intentName
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Metadata description of an AppIntent for contract verification.
public struct AppIntentDescriptor: Codable, Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let summaryTemplate: String?
    public let parameters: [String]
    public let supportsBackgroundExecution: Bool
    public let maxInputLength: Int

    public init(
        identifier: String,
        title: String,
        summaryTemplate: String? = nil,
        parameters: [String] = [],
        supportsBackgroundExecution: Bool = true,
        maxInputLength: Int = 32_768
    ) {
        self.identifier = identifier
        self.title = title
        self.summaryTemplate = summaryTemplate
        self.parameters = parameters
        self.supportsBackgroundExecution = supportsBackgroundExecution
        self.maxInputLength = maxInputLength
    }
}

/// Aggregated report of the App Intents & Siri Shortcuts schema audit.
public struct AppIntentsAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedIntentsCount: Int
    public let violations: [AppIntentViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedIntentsCount: Int,
        violations: [AppIntentViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedIntentsCount = evaluatedIntentsCount
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous auditor verifying that all App Intents, entity schemas, and Siri shortcut definitions
/// comply with macOS App Intents guidelines, parameter sanitization, and execution safety.
public enum AppIntentsContractAuditor {

    /// Canonical catalog of core ApexAgent App Intents registered for Siri and Shortcuts.
    public static func canonicalIntents() -> [AppIntentDescriptor] {
        [
            AppIntentDescriptor(
                identifier: "AskApexAgentIntent",
                title: "Ask Apex Agent",
                summaryTemplate: "Ask Apex Agent ${prompt}",
                parameters: ["prompt"],
                supportsBackgroundExecution: true,
                maxInputLength: 32_768
            ),
            AppIntentDescriptor(
                identifier: "TriggerRoutineIntent",
                title: "Trigger Routine",
                summaryTemplate: "Run Routine ${routineName}",
                parameters: ["routineName"],
                supportsBackgroundExecution: true,
                maxInputLength: 512
            ),
            AppIntentDescriptor(
                identifier: "InspectAgentStatusIntent",
                title: "Inspect Agent Status",
                summaryTemplate: "Check status of Apex Agent",
                parameters: [],
                supportsBackgroundExecution: true,
                maxInputLength: 0
            ),
            AppIntentDescriptor(
                identifier: "ExecutePlaybookIntent",
                title: "Execute Collaboration Playbook",
                summaryTemplate: "Run Playbook ${preset}",
                parameters: ["preset"],
                supportsBackgroundExecution: true,
                maxInputLength: 256
            ),
            AppIntentDescriptor(
                identifier: "FetchRecentSessionsIntent",
                title: "Fetch Recent Sessions",
                summaryTemplate: "Fetch ${limit} recent sessions",
                parameters: ["limit"],
                supportsBackgroundExecution: true,
                maxInputLength: 64
            ),
            AppIntentDescriptor(
                identifier: "SearchSessionsIntent",
                title: "Search Agent Sessions",
                summaryTemplate: "Search sessions matching ${query}",
                parameters: ["query"],
                supportsBackgroundExecution: true,
                maxInputLength: 1_024
            )
        ]
    }

    /// Allowed presets for `ExecutePlaybookIntent`.
    public static let validPlaybookPresets: Set<String> = [
        "pr_review", "pr", "issue_to_patch", "issue", "standup", "weekly_standup"
    ]

    /// Audits a set of intent descriptors against schema and contract rules.
    public static func audit(descriptors: [AppIntentDescriptor] = canonicalIntents()) -> AppIntentsAuditReport {
        guard !descriptors.isEmpty else {
            return AppIntentsAuditReport(
                passed: false,
                score: 0.0,
                evaluatedIntentsCount: 0,
                violations: [
                    AppIntentViolation(
                        intentName: "System",
                        ruleId: "INTENT-000",
                        severity: .critical,
                        message: "No AppIntent descriptors provided for audit.",
                        remediation: "Register at least one AppIntent descriptor."
                    )
                ],
                recommendations: ["Register canonical App Intents."]
            )
        }

        var violations: [AppIntentViolation] = []

        for desc in descriptors {
            // Rule 1: Title must not be empty or whitespace
            if desc.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                violations.append(
                    AppIntentViolation(
                        intentName: desc.identifier,
                        ruleId: "INTENT-001",
                        severity: .critical,
                        message: "Intent title cannot be empty or whitespace.",
                        remediation: "Provide a localized display title for the intent."
                    )
                )
            }

            // Rule 2: Title should be properly capitalized and readable
            if desc.title.count < 3 {
                violations.append(
                    AppIntentViolation(
                        intentName: desc.identifier,
                        ruleId: "INTENT-002",
                        severity: .high,
                        message: "Intent title '\(desc.title)' is too short to be descriptive.",
                        remediation: "Use a clear title like 'Ask Apex Agent'."
                    )
                )
            }

            // Rule 3: Summary template parameter binding parity
            if let summary = desc.summaryTemplate {
                for param in desc.parameters {
                    let expectedToken = "${\(param)}"
                    if !summary.contains(expectedToken) && !summary.contains(param) {
                        violations.append(
                            AppIntentViolation(
                                intentName: desc.identifier,
                                ruleId: "INTENT-003",
                                severity: .medium,
                                message: "Parameter '\(param)' is declared but missing from summary template '\(summary)'.",
                                remediation: "Include the parameter token in the summary template."
                            )
                        )
                    }
                }
            }

            // Rule 4: Max input length sanity
            if !desc.parameters.isEmpty && desc.maxInputLength <= 0 {
                violations.append(
                    AppIntentViolation(
                        intentName: desc.identifier,
                        ruleId: "INTENT-004",
                        severity: .high,
                        message: "Intent accepts parameters but specifies an invalid maxInputLength of \(desc.maxInputLength).",
                        remediation: "Set a positive maxInputLength ceiling to protect against buffer overflow."
                    )
                )
            }
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Harden AppIntent definitions with descriptive titles, complete summaries, and input length bounds.")
        }

        return AppIntentsAuditReport(
            passed: passed,
            score: score,
            evaluatedIntentsCount: descriptors.count,
            violations: violations,
            recommendations: recs
        )
    }

    /// Validates an incoming input argument against injection attacks and length boundaries.
    public static func validateInputArgument(
        _ input: String,
        parameterName: String,
        maxLength: Int = 32_768
    ) -> [AppIntentViolation] {
        var violations: [AppIntentViolation] = []

        if input.utf8.count > maxLength {
            violations.append(
                AppIntentViolation(
                    intentName: "InputValidation",
                    ruleId: "INP-001",
                    severity: .high,
                    message: "Parameter '\(parameterName)' exceeds maximum allowed length of \(maxLength) bytes (actual: \(input.utf8.count)).",
                    remediation: "Truncate or reject payloads exceeding maximum byte budget."
                )
            )
        }

        // Null-byte injection check
        if input.contains("\0") {
            violations.append(
                AppIntentViolation(
                    intentName: "InputValidation",
                    ruleId: "INP-002",
                    severity: .critical,
                    message: "Parameter '\(parameterName)' contains dangerous null byte characters.",
                    remediation: "Strip null bytes before passing to intent handlers."
                )
            )
        }

        return violations
    }
}
