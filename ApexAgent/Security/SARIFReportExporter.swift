import Foundation

// MARK: - SARIF v2.1.0 Security & Static Analysis Report Exporter (Batch 46)

/// Descriptor for a static analysis or security rule inside `runs[].tool.driver.rules`.
public struct SARIFRuleDescriptor: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let shortDescription: String
    public let defaultLevel: String

    public init(id: String, name: String, shortDescription: String, defaultLevel: String = "error") {
        self.id = id
        self.name = name
        self.shortDescription = shortDescription
        self.defaultLevel = defaultLevel
    }
}

/// A single SARIF finding inside `runs[].results`.
public struct SARIFResultItem: Sendable, Equatable, Codable {
    public let ruleId: String
    public let level: String
    public let message: String
    public let artifactURI: String
    public let startLine: Int

    public init(
        ruleId: String,
        level: String = "error",
        message: String,
        artifactURI: String,
        startLine: Int = 1
    ) {
        self.ruleId = ruleId
        self.level = level
        self.message = message
        self.artifactURI = artifactURI
        self.startLine = max(1, startLine)
    }
}

/// Aggregated SARIF v2.1.0 report bundle across all ApexAgent static analysis and security gates.
public struct SARIFReportBundle: Sendable, Equatable, Codable {
    public static let schemaURI = "https://json.schemastore.org/sarif-2.1.0.json"
    public static let sarifVersion = "2.1.0"
    public static let driverName = "ApexAgent Security & Static Analysis Suite"

    public let passed: Bool
    public let toolVersion: String
    public let rules: [SARIFRuleDescriptor]
    public let results: [SARIFResultItem]

    public init(
        passed: Bool,
        toolVersion: String = ApexCLIRouter.appVersion,
        rules: [SARIFRuleDescriptor],
        results: [SARIFResultItem]
    ) {
        self.passed = passed
        self.toolVersion = toolVersion
        self.rules = rules
        self.results = results
    }

    /// Serializes the report as an OASIS SARIF v2.1.0 JSON document.
    public func toSARIFJSON() -> String {
        let ruleObjects: [[String: Any]] = rules.map { rule in
            [
                "id": rule.id,
                "name": rule.name,
                "shortDescription": ["text": rule.shortDescription],
                "defaultConfiguration": ["level": rule.defaultLevel],
            ]
        }

        let resultObjects: [[String: Any]] = results.map { item in
            [
                "ruleId": item.ruleId,
                "level": item.level,
                "message": ["text": item.message],
                "locations": [
                    [
                        "physicalLocation": [
                            "artifactLocation": ["uri": item.artifactURI],
                            "region": ["startLine": item.startLine],
                        ]
                    ]
                ],
            ]
        }

        let root: [String: Any] = [
            "$schema": Self.schemaURI,
            "version": Self.sarifVersion,
            "runs": [
                [
                    "tool": [
                        "driver": [
                            "name": Self.driverName,
                            "version": toolVersion,
                            "informationUri": "https://github.com/dboone323/ApexAgent",
                            "rules": ruleObjects,
                        ]
                    ],
                    "results": resultObjects,
                ]
            ],
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## SARIF v2.1.0 Static Analysis Summary (`\(badge)`)",
            "",
            "- **Schema**: `\(Self.schemaURI)`",
            "- **Driver**: `\(Self.driverName) v\(toolVersion)`",
            "- **Registered Rules**: `\(rules.count)`",
            "- **Total Findings**: `\(results.count)`",
        ]
        if !results.isEmpty {
            lines.append("")
            lines.append("| Rule ID | Level | Location | Message |")
            lines.append("| :--- | :---: | :--- | :--- |")
            for item in results {
                lines.append("| `\(item.ruleId)` | `\(item.level)` | `\(item.artifactURI):\(item.startLine)` | \(item.message) |")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum SARIFReportExporter {
    /// Canonical catalog of SARIF rules emitted by ApexAgent's static analysis and security gates.
    public static let standardRules: [SARIFRuleDescriptor] = [
        SARIFRuleDescriptor(
            id: "APEX-HYGIENE-SECRET",
            name: "LeakedSecretOrPrivateKey",
            shortDescription: "Detects hardcoded API keys, tokens, or PEM private keys in tracked source files."
        ),
        SARIFRuleDescriptor(
            id: "APEX-HYGIENE-VENDOR",
            name: "ForbiddenVendorIdentifier",
            shortDescription: "Blocks forbidden third-party vendor-identifying symbol or file names."
        ),
        SARIFRuleDescriptor(
            id: "APEX-HYGIENE-PRINT",
            name: "RawPrintInProductionTarget",
            shortDescription: "Requires structured AppLog instead of raw standard-output logging calls in shipping targets."
        ),
        SARIFRuleDescriptor(
            id: "APEX-LINT-SYNTAX",
            name: "SwiftSyntaxAndStyleGate",
            shortDescription: "Enforces balanced delimiters, conflict-free sources, space indentation, and unique imports."
        ),
        SARIFRuleDescriptor(
            id: "APEX-DEPS-LOCK",
            name: "SupplyChainDependencyPinning",
            shortDescription: "Verifies HTTPS URLs, allowed GitHub orgs, 40-char commit SHAs, and manifest version parity."
        ),
        SARIFRuleDescriptor(
            id: "APEX-BUNDLE-INTEGRITY",
            name: "BundleEntitlementsAndBuildGraphParity",
            shortDescription: "Verifies entitlements, Info.plist URL schemes, and weak-linked framework parity."
        ),
        SARIFRuleDescriptor(
            id: "APEX-PRIVACY-DRIFT",
            name: "RequiredReasonAPIPrivacyDrift",
            shortDescription: "Verifies that all Required-Reason APIs used in source are declared in PrivacyInfo.xcprivacy."
        ),
    ]

    /// Builds a `SARIFReportBundle` from individual subsystem audit reports.
    public static func buildBundle(
        hygiene: RepoHygieneReport? = nil,
        syntaxLint: SyntaxLintReport? = nil,
        dependencyLock: DependencyLockAuditReport? = nil,
        bundleIntegrity: BundleIntegrityReport? = nil,
        privacyDrift: PrivacyManifestDriftReport? = nil
    ) -> SARIFReportBundle {
        var results: [SARIFResultItem] = []

        if let hygiene {
            for finding in hygiene.findings {
                let ruleId: String
                switch finding.category {
                case .leakedSecret:
                    ruleId = "APEX-HYGIENE-SECRET"
                case .forbiddenVendorName:
                    ruleId = "APEX-HYGIENE-VENDOR"
                case .rawPrintCall:
                    ruleId = "APEX-HYGIENE-PRINT"
                case .invalidPropertyList, .xcodeprojDrift:
                    ruleId = "APEX-BUNDLE-INTEGRITY"
                }
                results.append(
                    SARIFResultItem(
                        ruleId: ruleId,
                        level: "error",
                        message: finding.message,
                        artifactURI: finding.file,
                        startLine: max(1, finding.line)
                    )
                )
            }
        }

        if let syntaxLint {
            for issue in syntaxLint.issues {
                results.append(
                    SARIFResultItem(
                        ruleId: "APEX-LINT-SYNTAX",
                        level: "error",
                        message: "[\(issue.kind.rawValue)] \(issue.message)",
                        artifactURI: issue.file,
                        startLine: max(1, issue.line)
                    )
                )
            }
        }

        if let dependencyLock {
            for violation in dependencyLock.violations {
                results.append(
                    SARIFResultItem(
                        ruleId: "APEX-DEPS-LOCK",
                        level: "error",
                        message: "[\(violation.kind.rawValue)] \(violation.identity): \(violation.message)",
                        artifactURI: "Package.resolved",
                        startLine: 1
                    )
                )
            }
        }

        if let bundleIntegrity {
            for issue in bundleIntegrity.issues {
                results.append(
                    SARIFResultItem(
                        ruleId: "APEX-BUNDLE-INTEGRITY",
                        level: "error",
                        message: "[\(issue.kind.rawValue)] \(issue.message)",
                        artifactURI: issue.file,
                        startLine: 1
                    )
                )
            }
        }

        if let privacyDrift {
            for finding in privacyDrift.findings {
                results.append(
                    SARIFResultItem(
                        ruleId: "APEX-PRIVACY-DRIFT",
                        level: finding.severity == .error ? "error" : "warning",
                        message: "[\(finding.category)] \(finding.message)",
                        artifactURI: "ApexAgent/Resources/PrivacyInfo.xcprivacy",
                        startLine: 1
                    )
                )
            }
        }

        let hasErrors = results.contains { $0.level == "error" }
        return SARIFReportBundle(
            passed: !hasErrors,
            rules: standardRules,
            results: results
        )
    }

    /// Runs the repository static analysis and security gates at `rootURL` and exports a `SARIFReportBundle`.
    public static func exportRepositorySARIF(atRepoRoot rootURL: URL) -> SARIFReportBundle {
        let hygiene = RepoHygieneAuditor.auditRepository(at: rootURL)
        let deps = DependencyLockAuditor.auditRepository(atRepoRoot: rootURL)
        let bundle = BundleIntegrityVerifier.verifyRepositoryBundleIntegrity(atRepoRoot: rootURL)
        let privacy = PrivacyManifestDriftAuditor.auditWorkspace(at: rootURL)
        return buildBundle(
            hygiene: hygiene,
            dependencyLock: deps,
            bundleIntegrity: bundle,
            privacyDrift: privacy
        )
    }
}
