import Foundation

// MARK: - Batch 31: Pre-Push Fast Hygiene & Security Gate

/// Category of repository hygiene or security violation.
public enum RepoHygieneCategory: String, Codable, Sendable, CaseIterable {
    case leakedSecret
    case forbiddenVendorName
    case rawPrintCall
    case invalidPropertyList
    case xcodeprojDrift
}

/// A single hygiene or security finding produced by ``RepoHygieneAuditor``.
public struct RepoHygieneFinding: Codable, Sendable, Equatable {
    public let category: RepoHygieneCategory
    public let file: String
    public let line: Int
    public let message: String

    public init(category: RepoHygieneCategory, file: String, line: Int = 0, message: String) {
        self.category = category
        self.file = file
        self.line = line
        self.message = message
    }
}

/// Aggregate result of running ``RepoHygieneAuditor`` against a repository or fixture root.
public struct RepoHygieneReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let checkedFileCount: Int
    public let findings: [RepoHygieneFinding]
    public let durationMs: Double

    public init(passed: Bool, checkedFileCount: Int, findings: [RepoHygieneFinding], durationMs: Double) {
        self.passed = passed
        self.checkedFileCount = checkedFileCount
        self.findings = findings
        self.durationMs = durationMs
    }

    public func formatSummary() -> String {
        if passed {
            return String(format: "PASS: Repo hygiene audit clean (%d files checked in %.1fms, 0 findings).", checkedFileCount, durationMs)
        }
        var lines = [
            String(format: "FAIL: Repo hygiene audit found %d issue(s) across %d files (%.1fms):", findings.count, checkedFileCount, durationMs)
        ]
        for finding in findings {
            let loc = finding.line > 0 ? "\(finding.file):\(finding.line)" : finding.file
            lines.append("  [\(finding.category.rawValue)] \(loc) — \(finding.message)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Fast static hygiene and security gate for pre-push and CI verification.
public enum RepoHygieneAuditor {

    private static let secretPatterns: [(name: String, regex: NSRegularExpression)] = {
        let specs: [(String, String)] = [
            ("OpenAI/Anthropic API Key", #"sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,}"#),
            ("Google API Key", #"AIza[0-9A-Za-z_-]{35}"#),
            ("GitHub Personal Access Token", #"(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}"#),
            ("Slack Token", #"xox[baprs]-[0-9A-Za-z-]{20,}"#),
            ("AWS Access Key ID", #"AKIA[0-9A-Z]{16}"#),
            ("PEM Private Key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"#)
        ]
        return specs.compactMap { name, pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (name, regex)
        }
    }()

    private static let vendorRegex: NSRegularExpression = {
        // Matches grok, hermes, openclaw, openmaus (case-insensitive)
        try! NSRegularExpression(pattern: #"(?i)\b(?:grok|hermes|openclaw|openmaus)\b|[Gg]rok|[Hh]ermes|[Oo]pen[Cc]law|[Oo]pen[Mm]aus"#)
    }()

    private static let rawPrintRegex: NSRegularExpression = {
        // Matches standalone `print(` calls (not `.print(`, `debugPrint(`, or `"print("`)
        try! NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9_."'])print\s*\("#)
    }()

    /// Files where stdout `print()` is intentional (e.g. first-launch bootstrap token banner).
    private static let rawPrintAllowlistSuffixes: Set<String> = [
        "ApexAgent/Models/ApexGatewayServer.swift"
    ]

    // MARK: - Individual Scanners

    /// Scans `content` for leaked API keys, tokens, or PEM private keys.
    public static func scanForSecrets(in content: String, filePath: String) -> [RepoHygieneFinding] {
        var findings: [RepoHygieneFinding] = []
        let lines = content.components(separatedBy: .newlines)
        for (idx, lineText) in lines.enumerated() {
            let nsRange = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
            for (label, regex) in secretPatterns {
                if regex.firstMatch(in: lineText, options: [], range: nsRange) != nil {
                    findings.append(
                        RepoHygieneFinding(
                            category: .leakedSecret,
                            file: filePath,
                            line: idx + 1,
                            message: "Potential \(label) detected in source."
                        )
                    )
                }
            }
        }
        return findings
    }

    /// Scans `content` for forbidden third-party vendor/project names (`grok`, `hermes`, `openclaw`, `openmaus`).
    public static func scanForVendorNames(in content: String, filePath: String) -> [RepoHygieneFinding] {
        var findings: [RepoHygieneFinding] = []
        let lines = content.components(separatedBy: .newlines)
        for (idx, lineText) in lines.enumerated() {
            let nsRange = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
            if vendorRegex.firstMatch(in: lineText, options: [], range: nsRange) != nil {
                findings.append(
                    RepoHygieneFinding(
                        category: .forbiddenVendorName,
                        file: filePath,
                        line: idx + 1,
                        message: "Forbidden vendor-identifying name found in line."
                    )
                )
            }
        }
        return findings
    }

    /// Scans shipping `ApexAgent/` Swift code for raw `print(` calls that bypass `AppLog`.
    public static func scanForRawPrintCalls(in content: String, filePath: String) -> [RepoHygieneFinding] {
        if rawPrintAllowlistSuffixes.contains(where: { filePath.hasSuffix($0) }) {
            return []
        }
        var findings: [RepoHygieneFinding] = []
        let lines = content.components(separatedBy: .newlines)
        for (idx, lineText) in lines.enumerated() {
            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                continue
            }
            // Strip code comments at end of line before checking
            let codePart = trimmed.components(separatedBy: "//").first ?? trimmed
            // Ignore lines where `print(` only appears inside a double-quoted string literal
            let withoutQuotedStrings = Self.stripDoubleQuotedLiterals(from: codePart)
            let nsRange = NSRange(withoutQuotedStrings.startIndex..<withoutQuotedStrings.endIndex, in: withoutQuotedStrings)
            if rawPrintRegex.firstMatch(in: withoutQuotedStrings, options: [], range: nsRange) != nil {
                findings.append(
                    RepoHygieneFinding(
                        category: .rawPrintCall,
                        file: filePath,
                        line: idx + 1,
                        message: "Raw print() call in shipping code; use AppLog.<level>(.<category>, ...) instead."
                    )
                )
            }
        }
        return findings
    }

    private static func stripDoubleQuotedLiterals(from line: String) -> String {
        var result = ""
        var inQuotes = false
        var escaped = false
        for ch in line {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                escaped = true
                continue
            }
            if ch == "\"" {
                inQuotes.toggle()
                continue
            }
            if !inQuotes {
                result.append(ch)
            }
        }
        return result
    }

    /// Validates `Info.plist`, `PrivacyInfo.xcprivacy`, and `ApexAgent.entitlements` under `repoRoot`.
    public static func validatePropertyLists(atRepoRoot repoRoot: URL) -> [RepoHygieneFinding] {
        var findings: [RepoHygieneFinding] = []
        let relativePaths = [
            "ApexAgent/Info.plist",
            "ApexAgent/Resources/PrivacyInfo.xcprivacy",
            "ApexAgent/ApexAgent.entitlements"
        ]
        for rel in relativePaths {
            let url = repoRoot.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else {
                findings.append(
                    RepoHygieneFinding(
                        category: .invalidPropertyList,
                        file: rel,
                        message: "Required property list file is missing."
                    )
                )
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                guard let dict = plist as? [String: Any] else {
                    findings.append(
                        RepoHygieneFinding(
                            category: .invalidPropertyList,
                            file: rel,
                            message: "Top-level property list object is not a Dictionary."
                        )
                    )
                    continue
                }
                if rel.hasSuffix("Info.plist") && dict["CFBundleURLTypes"] == nil {
                    findings.append(
                        RepoHygieneFinding(
                            category: .invalidPropertyList,
                            file: rel,
                            message: "Info.plist is missing CFBundleURLTypes for apexagent:// deep links."
                        )
                    )
                }
                if rel.hasSuffix("PrivacyInfo.xcprivacy") && dict["NSPrivacyAccessedAPITypes"] == nil {
                    findings.append(
                        RepoHygieneFinding(
                            category: .invalidPropertyList,
                            file: rel,
                            message: "PrivacyInfo.xcprivacy is missing NSPrivacyAccessedAPITypes."
                        )
                    )
                }
            } catch {
                findings.append(
                    RepoHygieneFinding(
                        category: .invalidPropertyList,
                        file: rel,
                        message: "Invalid XML/PropertyList syntax: \(error.localizedDescription)"
                    )
                )
            }
        }
        return findings
    }

    /// Verifies that every `.swift` file in `ApexAgent/` and `ApexAgentTests/` is registered in `ApexAgent.xcodeproj/project.pbxproj`.
    public static func checkXcodeprojSync(atRepoRoot repoRoot: URL) -> [RepoHygieneFinding] {
        let canonicalRoot = repoRoot.resolvingSymlinksInPath()
        let pbxprojURL = canonicalRoot.appendingPathComponent("ApexAgent.xcodeproj/project.pbxproj")
        guard let pbxContent = try? String(contentsOf: pbxprojURL, encoding: .utf8) else {
            return [
                RepoHygieneFinding(
                    category: .xcodeprojDrift,
                    file: "ApexAgent.xcodeproj/project.pbxproj",
                    message: "Unable to read project.pbxproj."
                )
            ]
        }

        var findings: [RepoHygieneFinding] = []
        let sourceDirs = ["ApexAgent", "ApexAgentTests"]
        for dirName in sourceDirs {
            let dirURL = canonicalRoot.appendingPathComponent(dirName)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let filename = fileURL.lastPathComponent
                if !pbxContent.contains(filename) {
                    let canonicalFile = fileURL.resolvingSymlinksInPath().path
                    let relPath = canonicalFile.replacingOccurrences(of: canonicalRoot.path + "/", with: "")
                    findings.append(
                        RepoHygieneFinding(
                            category: .xcodeprojDrift,
                            file: relPath,
                            message: "Swift file '\(filename)' is not registered in project.pbxproj; run 'xcodegen generate'."
                        )
                    )
                }
            }
        }
        return findings
    }

    // MARK: - Full Repository Audit

    /// Runs all 5 static hygiene and security checks against `repoRoot`.
    public static func auditRepository(at repoRoot: URL) -> RepoHygieneReport {
        let start = CFAbsoluteTimeGetCurrent()
        let canonicalRoot = repoRoot.resolvingSymlinksInPath()
        var findings: [RepoHygieneFinding] = []
        var checkedFiles = 0

        let scanDirs = ["ApexAgent", "ApexAgentTests", "ApexAgentUITests"]
        for dirName in scanDirs {
            let dirURL = canonicalRoot.appendingPathComponent(dirName)
            guard let enumerator = FileManager.default.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                checkedFiles += 1
                let canonicalFile = fileURL.resolvingSymlinksInPath().path
                let relPath = canonicalFile.replacingOccurrences(of: canonicalRoot.path + "/", with: "")

                if dirName == "ApexAgent" {
                    findings.append(contentsOf: scanForSecrets(in: content, filePath: relPath))
                    findings.append(contentsOf: scanForRawPrintCalls(in: content, filePath: relPath))
                }
                // Skip self-reference inside RepoHygieneAuditor and its test file when checking vendor regex literals
                if !relPath.hasSuffix("RepoHygieneAuditor.swift") && !relPath.hasSuffix("RepoHygieneAuditorTests.swift") {
                    findings.append(contentsOf: scanForVendorNames(in: content, filePath: relPath))
                }
            }
        }

        findings.append(contentsOf: validatePropertyLists(atRepoRoot: repoRoot))
        findings.append(contentsOf: checkXcodeprojSync(atRepoRoot: repoRoot))

        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return RepoHygieneReport(
            passed: findings.isEmpty,
            checkedFileCount: checkedFiles,
            findings: findings,
            durationMs: durationMs
        )
    }
}
