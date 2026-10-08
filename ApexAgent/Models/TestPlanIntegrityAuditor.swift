import Foundation

// MARK: - Xcode .xctestplan Parity, Timeout & Coverage Target Auditor (Batch 47)

/// Parsed representation of a single `.xctestplan` file.
public struct ParsedTestPlan: Sendable, Equatable, Codable {
    public let name: String
    public let version: Int
    public let testModeEnvironmentEnabled: Bool
    public let testTimeoutsEnabled: Bool
    public let defaultTimeoutSeconds: Int
    public let maximumTimeoutSeconds: Int
    public let coverageTargetNames: [String]
    public let testTargetNames: [String]
    public let skippedTests: [String]

    public init(
        name: String,
        version: Int,
        testModeEnvironmentEnabled: Bool,
        testTimeoutsEnabled: Bool,
        defaultTimeoutSeconds: Int,
        maximumTimeoutSeconds: Int,
        coverageTargetNames: [String],
        testTargetNames: [String],
        skippedTests: [String]
    ) {
        self.name = name
        self.version = version
        self.testModeEnvironmentEnabled = testModeEnvironmentEnabled
        self.testTimeoutsEnabled = testTimeoutsEnabled
        self.defaultTimeoutSeconds = defaultTimeoutSeconds
        self.maximumTimeoutSeconds = maximumTimeoutSeconds
        self.coverageTargetNames = coverageTargetNames
        self.testTargetNames = testTargetNames
        self.skippedTests = skippedTests
    }
}

/// Complete audit report from `TestPlanIntegrityAuditor`.
public struct TestPlanIntegrityReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let plans: [ParsedTestPlan]
    public let findings: [String]

    public init(passed: Bool, plans: [ParsedTestPlan], findings: [String]) {
        self.passed = passed
        self.plans = plans
        self.findings = findings
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Xcode Test Plan Integrity Audit (`\(badge)`)",
            "",
            "| Test Plan | Targets | Coverage Targets | Timeouts (Default/Max) | `APEX_TEST_MODE=1` | Skipped Tests |",
            "| :--- | :--- | :---: | :---: | :---: | :---: |",
        ]
        for plan in plans {
            lines.append(
                "| `\(plan.name)` | `\(plan.testTargetNames.joined(separator: ", "))` | \(plan.coverageTargetNames.count) | \(plan.defaultTimeoutSeconds)s / \(plan.maximumTimeoutSeconds)s | \(plan.testModeEnvironmentEnabled ? "YES" : "NO") | \(plan.skippedTests.count) |"
            )
        }
        if !findings.isEmpty {
            lines.append("")
            lines.append("### Findings")
            for finding in findings {
                lines.append("- \(finding)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum TestPlanIntegrityError: Error, LocalizedError, Equatable {
    case invalidJSON

    public var errorDescription: String? {
        "Test plan file is not a valid JSON dictionary."
    }
}

public enum TestPlanIntegrityAuditor {
    public static let requiredUnitTestTargets: [String] = [
        "ApexAgentTests",
        "ApexAgentIntelligenceTests",
        "ApexAgentContainerTests",
    ]

    public static let requiredUITestTargets: [String] = [
        "ApexAgentUITests",
    ]

    /// Parses raw `.xctestplan` JSON data into a `ParsedTestPlan`.
    public static func parseTestPlan(data: Data, name: String) throws -> ParsedTestPlan {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestPlanIntegrityError.invalidJSON
        }

        let version = root["version"] as? Int ?? 0

        var testModeEnabled = false
        if let configs = root["configurations"] as? [[String: Any]] {
            for config in configs {
                let options = config["options"] as? [String: Any] ?? [:]
                let envEntries = options["environmentVariableEntries"] as? [[String: Any]] ?? []
                for entry in envEntries {
                    let key = entry["key"] as? String ?? ""
                    let val = entry["value"] as? String ?? ""
                    let enabled = (entry["enabled"] as? Bool) ?? true
                    if key == "APEX_TEST_MODE" && val == "1" && enabled {
                        testModeEnabled = true
                    }
                }
            }
        }

        let defaultOptions = root["defaultOptions"] as? [String: Any] ?? [:]
        let timeoutsEnabled = (defaultOptions["testTimeoutsEnabled"] as? Bool) ?? false
        let defaultTimeout = defaultOptions["defaultTestExecutionTimeAllowance"] as? Int ?? 0
        let maxTimeout = defaultOptions["maximumTestExecutionTimeAllowance"] as? Int ?? 0

        var coverageTargets: [String] = []
        if let codeCoverage = defaultOptions["codeCoverage"] as? [String: Any],
           let rawCovTargets = codeCoverage["targets"] as? [[String: Any]] {
            for item in rawCovTargets {
                if let targetName = item["name"] as? String {
                    coverageTargets.append(targetName)
                }
            }
        }

        var testTargets: [String] = []
        var skipped: [String] = []
        if let rawTestTargets = root["testTargets"] as? [[String: Any]] {
            for entry in rawTestTargets {
                if let enabled = entry["enabled"] as? Bool, !enabled {
                    let disabledName = (entry["target"] as? [String: Any])?["name"] as? String ?? "unknown"
                    skipped.append("target:\(disabledName)")
                }
                if let targetDict = entry["target"] as? [String: Any],
                   let targetName = targetDict["name"] as? String {
                    testTargets.append(targetName)
                }
                if let rawSkipped = entry["skippedTests"] as? [String] {
                    skipped.append(contentsOf: rawSkipped)
                }
            }
        }

        return ParsedTestPlan(
            name: name,
            version: version,
            testModeEnvironmentEnabled: testModeEnabled,
            testTimeoutsEnabled: timeoutsEnabled,
            defaultTimeoutSeconds: defaultTimeout,
            maximumTimeoutSeconds: maxTimeout,
            coverageTargetNames: coverageTargets,
            testTargetNames: testTargets,
            skippedTests: skipped
        )
    }

    /// Evaluates parsed unit and UI test plans against ApexAgent's CI/CD test plan invariants.
    public static func evaluate(
        unitPlan: ParsedTestPlan,
        uiPlan: ParsedTestPlan
    ) -> TestPlanIntegrityReport {
        var findings: [String] = []

        for plan in [unitPlan, uiPlan] {
            if plan.version != 1 {
                findings.append("\(plan.name): expected version 1, found \(plan.version).")
            }
            if !plan.testModeEnvironmentEnabled {
                findings.append("\(plan.name): missing enabled APEX_TEST_MODE=1 environment variable in configurations.")
            }
            if !plan.testTimeoutsEnabled {
                findings.append("\(plan.name): testTimeoutsEnabled must be true to prevent hung CI runners.")
            }
            if plan.defaultTimeoutSeconds <= 0 || plan.defaultTimeoutSeconds > 180 {
                findings.append("\(plan.name): defaultTestExecutionTimeAllowance (\(plan.defaultTimeoutSeconds)s) must be in 1...180s.")
            }
            if plan.maximumTimeoutSeconds < plan.defaultTimeoutSeconds || plan.maximumTimeoutSeconds > 360 {
                findings.append("\(plan.name): maximumTestExecutionTimeAllowance (\(plan.maximumTimeoutSeconds)s) must be in \(plan.defaultTimeoutSeconds)...360s.")
            }
            if !plan.skippedTests.isEmpty {
                findings.append("\(plan.name): contains unexpected skippedTests: \(plan.skippedTests.joined(separator: ", ")).")
            }
        }

        if !unitPlan.coverageTargetNames.contains("ApexAgentCore") {
            findings.append("\(unitPlan.name): codeCoverage.targets must include 'ApexAgentCore'.")
        }

        for reqTarget in requiredUnitTestTargets where !unitPlan.testTargetNames.contains(reqTarget) {
            findings.append("\(unitPlan.name): missing required unit test target '\(reqTarget)'.")
        }

        for reqUITarget in requiredUITestTargets where !uiPlan.testTargetNames.contains(reqUITarget) {
            findings.append("\(uiPlan.name): missing required UI test target '\(reqUITarget)'.")
        }

        return TestPlanIntegrityReport(
            passed: findings.isEmpty,
            plans: [unitPlan, uiPlan],
            findings: findings
        )
    }

    /// Audits `ApexAgent-UnitTests.xctestplan` and `ApexAgent-UITests.xctestplan` at `rootURL`.
    public static func auditRepositoryTestPlans(atRepoRoot rootURL: URL) -> TestPlanIntegrityReport {
        let unitURL = rootURL.appendingPathComponent("ApexAgent-UnitTests.xctestplan")
        let uiURL = rootURL.appendingPathComponent("ApexAgent-UITests.xctestplan")

        guard let unitData = try? Data(contentsOf: unitURL),
              let unitPlan = try? parseTestPlan(data: unitData, name: "ApexAgent-UnitTests.xctestplan"),
              let uiData = try? Data(contentsOf: uiURL),
              let uiPlan = try? parseTestPlan(data: uiData, name: "ApexAgent-UITests.xctestplan") else {
            return TestPlanIntegrityReport(
                passed: false,
                plans: [],
                findings: ["Unable to load or parse ApexAgent-UnitTests.xctestplan and ApexAgent-UITests.xctestplan."]
            )
        }

        return evaluate(unitPlan: unitPlan, uiPlan: uiPlan)
    }
}
