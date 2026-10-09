import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Spotlight Search Contract & Index Attribute Integrity Auditor (Batch 56)

/// Severity of a Spotlight index contract violation.
public enum SpotlightViolationSeverity: String, Codable, Sendable, Comparable {
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

    public static func < (lhs: SpotlightViolationSeverity, rhs: SpotlightViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// A specific defect detected in a Spotlight `CSSearchableItem` attribute set.
public struct SpotlightContractViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(uniqueIdentifier):\(ruleId):\(message)" }
    public let uniqueIdentifier: String
    public let domain: String
    public let ruleId: String
    public let severity: SpotlightViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        uniqueIdentifier: String,
        domain: String,
        ruleId: String,
        severity: SpotlightViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.uniqueIdentifier = uniqueIdentifier
        self.domain = domain
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Aggregated report of Spotlight searchable index contract verification.
public struct SpotlightContractAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let auditedItems: Int
    public let validDomainsCount: Int
    public let violations: [SpotlightContractViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        auditedItems: Int,
        validDomainsCount: Int,
        violations: [SpotlightContractViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.auditedItems = auditedItems
        self.validDomainsCount = validDomainsCount
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Spotlight Search Contract & Index Attribute Audit (`\(badge)`)",
            "",
            "- **Compliance Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **Items Audited**: `\(auditedItems)`",
            "- **Recognized Domains Covered**: `\(validDomainsCount)`",
            "- **Violations Detected**: `\(violations.count)`",
            ""
        ]

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| Identifier | Domain | Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :--- | :--- | :---: | :--- | :--- |")
            for v in violations {
                lines.append("| `\(v.uniqueIdentifier)` | `\(v.domain)` | `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
            }
            lines.append("")
        }

        if !recommendations.isEmpty {
            lines.append("### Hardening Recommendations")
            for r in recommendations {
                lines.append("- \(r)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

/// Auditor verifying Spotlight searchable items against contract requirements.
public enum SpotlightContractAuditor {
    /// The official registered domain identifiers supported by ApexAgent.
    public static let approvedDomains: Set<String> = [
        SpotlightIndexer.domainIdentifier,          // Sessions
        SpotlightIndexer.spacesDomainIdentifier,    // Spaces
        SpotlightIndexer.botsDomainIdentifier,      // Bots
        SpotlightIndexer.routinesDomainIdentifier,  // Routines
        SpotlightIndexer.skillsDomainIdentifier,    // Skills
        SpotlightIndexer.commandsDomainIdentifier   // Commands
    ]

    /// Evaluates an individual `CSSearchableItem` against attribute set contracts.
    public static func auditItem(_ item: CSSearchableItem) -> [SpotlightContractViolation] {
        var violations: [SpotlightContractViolation] = []
        let id = item.uniqueIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = item.domainIdentifier ?? "unspecified"

        // 1. Identifier presence
        if id.isEmpty {
            violations.append(
                SpotlightContractViolation(
                    uniqueIdentifier: "<blank>",
                    domain: domain,
                    ruleId: "spotlight_empty_unique_id",
                    severity: .critical,
                    message: "Searchable item has empty or whitespace uniqueIdentifier.",
                    remediation: "Provide a stable unique identifier string."
                )
            )
        }

        // 2. Domain identifier validation
        if !approvedDomains.contains(domain) {
            violations.append(
                SpotlightContractViolation(
                    uniqueIdentifier: id,
                    domain: domain,
                    ruleId: "spotlight_unregistered_domain",
                    severity: .critical,
                    message: "Domain identifier '\(domain)' is not registered in SpotlightIndexer domain catalog.",
                    remediation: "Assign one of the 6 official domain identifiers."
                )
            )
        }

        let attrs = item.attributeSet

        // 3. Title check
        let title = attrs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty {
            violations.append(
                SpotlightContractViolation(
                    uniqueIdentifier: id,
                    domain: domain,
                    ruleId: "spotlight_missing_title",
                    severity: .high,
                    message: "Searchable item attribute set is missing a title.",
                    remediation: "Populate attributes.title with human-readable item label."
                )
            )
        }

        // 4. Content description
        let desc = attrs.contentDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if desc.isEmpty {
            violations.append(
                SpotlightContractViolation(
                    uniqueIdentifier: id,
                    domain: domain,
                    ruleId: "spotlight_missing_description",
                    severity: .medium,
                    message: "Searchable item attribute set is missing contentDescription.",
                    remediation: "Populate attributes.contentDescription with searchable summary or text."
                )
            )
        }

        // 5. Keywords enrichment
        let keywords = attrs.keywords ?? []
        if keywords.isEmpty {
            violations.append(
                SpotlightContractViolation(
                    uniqueIdentifier: id,
                    domain: domain,
                    ruleId: "spotlight_empty_keywords",
                    severity: .medium,
                    message: "Searchable item has no keywords specified.",
                    remediation: "Enrich attributes.keywords with domain-specific search tags."
                )
            )
        }

        // 6. Deep link URL resolution
        if let url = attrs.contentURL {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme != "apexagent" {
                violations.append(
                    SpotlightContractViolation(
                        uniqueIdentifier: id,
                        domain: domain,
                        ruleId: "spotlight_invalid_url_scheme",
                        severity: .high,
                        message: "Content URL '\(url)' does not use registered 'apexagent://' scheme.",
                        remediation: "Construct deep links via DeepLinkRouter."
                    )
                )
            }
        } else {
            // For items that require deep links (conversations, routines, skills, commands)
            if domain == SpotlightIndexer.domainIdentifier ||
                domain == SpotlightIndexer.routinesDomainIdentifier ||
                domain == SpotlightIndexer.skillsDomainIdentifier ||
                domain == SpotlightIndexer.commandsDomainIdentifier {
                violations.append(
                    SpotlightContractViolation(
                        uniqueIdentifier: id,
                        domain: domain,
                        ruleId: "spotlight_missing_deeplink_url",
                        severity: .high,
                        message: "Item in domain '\(domain)' requires deep link contentURL for system handoff.",
                        remediation: "Set attributes.contentURL using DeepLinkRouter.url(for:)."
                    )
                )
            }
        }

        return violations
    }

    /// Evaluates a collection of searchable items and produces an aggregated audit report.
    public static func auditItems(_ items: [CSSearchableItem]) -> SpotlightContractAuditReport {
        var allViolations: [SpotlightContractViolation] = []
        var domainsSeen = Set<String>()

        for item in items {
            if let d = item.domainIdentifier, approvedDomains.contains(d) {
                domainsSeen.insert(d)
            }
            allViolations.append(contentsOf: auditItem(item))
        }

        var deduction = 0.0
        for v in allViolations {
            switch v.severity {
            case .critical: deduction += 35.0
            case .high: deduction += 20.0
            case .medium: deduction += 10.0
            case .low: deduction += 5.0
            case .info: deduction += 1.0
            }
        }

        let finalScore = max(0.0, 100.0 - deduction)
        let hasCriticalOrHigh = allViolations.contains(where: { $0.severity == .critical || $0.severity == .high })
        let passed = finalScore >= 70.0 && !hasCriticalOrHigh

        var recommendations: [String] = []
        if !allViolations.isEmpty {
            recommendations.append("Ensure every indexed item provides a non-blank title and keyword tag set.")
            recommendations.append("Ensure searchable items targeting handoff specify a valid apexagent:// deep link.")
            recommendations.append("Restrain domain identifiers strictly to the 6 official bundle domains.")
        } else {
            recommendations.append("All Spotlight searchable items comply with Core Spotlight attribute contracts.")
        }

        return SpotlightContractAuditReport(
            passed: passed,
            score: finalScore,
            auditedItems: items.count,
            validDomainsCount: domainsSeen.count,
            violations: allViolations,
            recommendations: recommendations
        )
    }
}
