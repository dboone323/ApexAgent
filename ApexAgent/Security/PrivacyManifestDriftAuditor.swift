import Foundation

// MARK: - Workspace-Wide Required-Reason API & Privacy Manifest Drift Auditor (Batch 42)

/// Records a single Required-Reason API call site discovered in Swift source code.
public struct PrivacyAPIUsageOccurrence: Sendable, Equatable, Codable {
    public let filePath: String
    public let lineNumber: Int
    public let category: String
    public let matchedSymbol: String

    public init(filePath: String, lineNumber: Int, category: String, matchedSymbol: String) {
        self.filePath = filePath
        self.lineNumber = lineNumber
        self.category = category
        self.matchedSymbol = matchedSymbol
    }
}

/// A finding emitted by `PrivacyManifestDriftAuditor`.
public struct PrivacyManifestDriftFinding: Sendable, Equatable, Codable {
    public enum Severity: String, Sendable, Equatable, Codable {
        case error
        case warning
    }

    public let severity: Severity
    public let category: String
    public let message: String

    public init(severity: Severity, category: String, message: String) {
        self.severity = severity
        self.category = category
        self.message = message
    }
}

/// Complete workspace-wide privacy manifest drift report.
public struct PrivacyManifestDriftReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let scannedFileCount: Int
    public let detectedCategories: [String]
    public let declaredCategories: [String]
    public let missingCategories: [String]
    public let invalidReasonCodes: [String]
    public let occurrencesByCategory: [String: Int]
    public let findings: [PrivacyManifestDriftFinding]

    public init(
        passed: Bool,
        scannedFileCount: Int,
        detectedCategories: [String],
        declaredCategories: [String],
        missingCategories: [String],
        invalidReasonCodes: [String],
        occurrencesByCategory: [String: Int],
        findings: [PrivacyManifestDriftFinding]
    ) {
        self.passed = passed
        self.scannedFileCount = scannedFileCount
        self.detectedCategories = detectedCategories
        self.declaredCategories = declaredCategories
        self.missingCategories = missingCategories
        self.invalidReasonCodes = invalidReasonCodes
        self.occurrencesByCategory = occurrencesByCategory
        self.findings = findings
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Privacy Manifest Drift Audit (`\(badge)`)",
            "",
            "- **Scanned Swift Files**: `\(scannedFileCount)`",
            "- **Detected Categories**: `\(detectedCategories.joined(separator: ", "))`",
            "- **Declared Categories**: `\(declaredCategories.joined(separator: ", "))`",
            "- **Missing Categories**: `\(missingCategories.isEmpty ? "none" : missingCategories.joined(separator: ", "))`",
            "",
            "| Category | Source Occurrences | Declared in `PrivacyInfo.xcprivacy` |",
            "| :--- | :---: | :---: |",
        ]

        let allCategories = Set(detectedCategories).union(declaredCategories).sorted()
        for category in allCategories {
            let count = occurrencesByCategory[category] ?? 0
            let isDeclared = declaredCategories.contains(category) ? "YES" : "NO"
            lines.append("| `\(category)` | \(count) | \(isDeclared) |")
        }

        if !findings.isEmpty {
            lines.append("")
            lines.append("### Findings")
            for finding in findings {
                lines.append("- **[\(finding.severity.rawValue.uppercased())]** (`\(finding.category)`): \(finding.message)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum PrivacyManifestDriftAuditor {
    /// Official Apple Required-Reason API reason code allowlist per category.
    public static let allowedReasonCodesByCategory: [String: Set<String>] = [
        PrivacyManifestInspector.userDefaultsCategory: ["CA92.1", "1C8F.1", "C56D.1", "AC6B.1"],
        PrivacyManifestInspector.fileTimestampCategory: ["DDA9.1", "C617.1", "3B52.1", "0A2A.1"],
        PrivacyManifestInspector.diskSpaceCategory: ["85F4.1", "E174.1", "7D9E.1", "B728.1"],
        PrivacyManifestInspector.systemBootTimeCategory: ["35F9.1", "8FFB.1", "3D61.1"],
        "NSPrivacyAccessedAPICategoryActiveKeyboards": ["3EC4.1", "54BD.1"],
    ]

    private static let excludedFilenames: Set<String> = [
        "PrivacyManifestInspector.swift",
        "PrivacyManifestDriftAuditor.swift",
    ]

    /// Audits the workspace at `rootURL` against `ApexAgent/Resources/PrivacyInfo.xcprivacy`.
    public static func auditWorkspace(at rootURL: URL) -> PrivacyManifestDriftReport {
        let manifestURL = rootURL.appendingPathComponent("ApexAgent/Resources/PrivacyInfo.xcprivacy")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? PrivacyManifestInspector.parse(data: manifestData) else {
            return PrivacyManifestDriftReport(
                passed: false,
                scannedFileCount: 0,
                detectedCategories: [],
                declaredCategories: [],
                missingCategories: [],
                invalidReasonCodes: [],
                occurrencesByCategory: [:],
                findings: [
                    PrivacyManifestDriftFinding(
                        severity: .error,
                        category: "manifest",
                        message: "Unable to load or parse ApexAgent/Resources/PrivacyInfo.xcprivacy."
                    )
                ]
            )
        }

        var swiftFiles: [URL] = []
        let scanDirs = ["ApexAgent", "ApexAgentRuntime"]
        for dir in scanDirs {
            let dirURL = rootURL.appendingPathComponent(dir)
            if let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                    if !excludedFilenames.contains(fileURL.lastPathComponent) {
                        swiftFiles.append(fileURL)
                    }
                }
            }
        }

        var sourcesByPath: [String: String] = [:]
        for fileURL in swiftFiles {
            if let source = try? String(contentsOf: fileURL, encoding: .utf8) {
                let relPath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                sourcesByPath[relPath] = source
            }
        }

        return evaluate(manifest: manifest, sourcesByPath: sourcesByPath)
    }

    /// Evaluates a parsed `PrivacyManifestReport` against a dictionary of `[relativePath: swiftSource]`.
    public static func evaluate(
        manifest: PrivacyManifestReport,
        sourcesByPath: [String: String]
    ) -> PrivacyManifestDriftReport {
        var occurrences: [PrivacyAPIUsageOccurrence] = []
        var occurrencesByCategory: [String: Int] = [:]

        for (path, source) in sourcesByPath.sorted(by: { $0.key < $1.key }) {
            let lines = source.components(separatedBy: .newlines)
            for (idx, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") {
                    continue
                }
                for (category, symbol) in detectCategoriesOnLine(trimmed) {
                    occurrences.append(
                        PrivacyAPIUsageOccurrence(
                            filePath: path,
                            lineNumber: idx + 1,
                            category: category,
                            matchedSymbol: symbol
                        )
                    )
                    occurrencesByCategory[category, default: 0] += 1
                }
            }
        }

        let detectedSet = Set(occurrencesByCategory.keys)
        let declaredSet = Set(manifest.accessedAPITypes.filter { !$0.reasons.isEmpty }.map(\.apiType))
        let missingCategories = manifest.missingCategories(for: detectedSet)

        var findings: [PrivacyManifestDriftFinding] = []
        var invalidReasonCodes: [String] = []

        // 1. Check for missing Required-Reason API categories
        for missing in missingCategories {
            let sample = occurrences.first { $0.category == missing }
            let locationHint = sample.map { " (e.g., \($0.filePath):\($0.lineNumber) via `\($0.matchedSymbol)`)" } ?? ""
            findings.append(
                PrivacyManifestDriftFinding(
                    severity: .error,
                    category: missing,
                    message: "Required-Reason API category '\(missing)' is used in source\(locationHint) but missing from PrivacyInfo.xcprivacy."
                )
            )
        }

        // 2. Validate every declared API category and its reason codes against Apple's allowlist
        for declaration in manifest.accessedAPITypes {
            if declaration.reasons.isEmpty {
                findings.append(
                    PrivacyManifestDriftFinding(
                        severity: .error,
                        category: declaration.apiType,
                        message: "Category '\(declaration.apiType)' is declared with an empty NSPrivacyAccessedAPITypeReasons array."
                    )
                )
                continue
            }
            if let allowed = allowedReasonCodesByCategory[declaration.apiType] {
                for reason in declaration.reasons where !allowed.contains(reason) {
                    invalidReasonCodes.append("\(declaration.apiType):\(reason)")
                    findings.append(
                        PrivacyManifestDriftFinding(
                            severity: .error,
                            category: declaration.apiType,
                            message: "Reason code '\(reason)' is not a valid Apple Required-Reason code for '\(declaration.apiType)'."
                        )
                    )
                }
            } else {
                findings.append(
                    PrivacyManifestDriftFinding(
                        severity: .error,
                        category: declaration.apiType,
                        message: "Unknown NSPrivacyAccessedAPIType '\(declaration.apiType)' in PrivacyInfo.xcprivacy."
                    )
                )
            }
        }

        // 3. Validate collected data declarations have non-empty purposes
        for collected in manifest.collectedDataTypes where collected.purposes.isEmpty {
            findings.append(
                PrivacyManifestDriftFinding(
                    severity: .error,
                    category: collected.dataType,
                    message: "Collected data type '\(collected.dataType)' must declare at least one purpose in NSPrivacyCollectedDataTypePurposes."
                )
            )
        }

        let hasErrors = findings.contains { $0.severity == .error }
        return PrivacyManifestDriftReport(
            passed: !hasErrors,
            scannedFileCount: sourcesByPath.count,
            detectedCategories: detectedSet.sorted(),
            declaredCategories: declaredSet.sorted(),
            missingCategories: missingCategories,
            invalidReasonCodes: invalidReasonCodes.sorted(),
            occurrencesByCategory: occurrencesByCategory,
            findings: findings
        )
    }

    private static func detectCategoriesOnLine(_ line: String) -> [(String, String)] {
        var matched: [(String, String)] = []
        if line.contains("UserDefaults") {
            matched.append((PrivacyManifestInspector.userDefaultsCategory, "UserDefaults"))
        } else if line.contains("@AppStorage") {
            matched.append((PrivacyManifestInspector.userDefaultsCategory, "@AppStorage"))
        }

        if line.contains("attributesOfItem(") {
            matched.append((PrivacyManifestInspector.fileTimestampCategory, "attributesOfItem"))
        } else if line.contains(".creationDate") {
            matched.append((PrivacyManifestInspector.fileTimestampCategory, ".creationDate"))
        } else if line.contains(".contentModificationDateKey") {
            matched.append((PrivacyManifestInspector.fileTimestampCategory, ".contentModificationDateKey"))
        }

        if line.contains("volumeAvailableCapacity") {
            matched.append((PrivacyManifestInspector.diskSpaceCategory, "volumeAvailableCapacity"))
        } else if line.contains("volumeTotalCapacityKey") {
            matched.append((PrivacyManifestInspector.diskSpaceCategory, "volumeTotalCapacityKey"))
        } else if line.contains(".systemFreeSize") {
            matched.append((PrivacyManifestInspector.diskSpaceCategory, ".systemFreeSize"))
        } else if line.contains(".systemSize") {
            matched.append((PrivacyManifestInspector.diskSpaceCategory, ".systemSize"))
        }

        let bootSymbol = "." + "systemUptime"
        if line.contains(bootSymbol) {
            matched.append((PrivacyManifestInspector.systemBootTimeCategory, bootSymbol))
        }
        return matched
    }
}
