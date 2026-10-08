import Foundation

// MARK: - Conventional Changelog Generator, SemVer Bump Calculator & Release Version Parity Gate (Batch 43)

/// Semantic version triple (`MAJOR.MINOR.PATCH`).
public struct SemanticVersion: Sendable, Equatable, Comparable, Codable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 && parts.count <= 3 else { return nil }
        self.major = parts[0]
        self.minor = parts[1]
        self.patch = parts.count == 3 ? parts[2] : 0
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Level of semantic version bump required by a set of commits.
public enum SemVerBumpLevel: String, Sendable, Equatable, Codable {
    case none
    case patch
    case minor
    case major
}

/// Parsed representation of a single git commit for changelog generation.
public struct ChangelogCommitEntry: Sendable, Equatable, Codable {
    public let sha: String
    public let type: String
    public let scope: String?
    public let isBreaking: Bool
    public let summary: String

    public init(sha: String, type: String, scope: String?, isBreaking: Bool, summary: String) {
        self.sha = sha
        self.type = type
        self.scope = scope
        self.isBreaking = isBreaking
        self.summary = summary
    }
}

/// Result of auditing release version metadata across `Info.plist` and `project.yml`.
public struct ReleaseVersionParityReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let shortVersionString: String
    public let bundleVersion: String
    public let cliRouterVersion: String
    public let nextSuggestedVersion: String
    public let bumpLevel: SemVerBumpLevel
    public let findings: [String]

    public init(
        passed: Bool,
        shortVersionString: String,
        bundleVersion: String,
        cliRouterVersion: String,
        nextSuggestedVersion: String,
        bumpLevel: SemVerBumpLevel,
        findings: [String]
    ) {
        self.passed = passed
        self.shortVersionString = shortVersionString
        self.bundleVersion = bundleVersion
        self.cliRouterVersion = cliRouterVersion
        self.nextSuggestedVersion = nextSuggestedVersion
        self.bumpLevel = bumpLevel
        self.findings = findings
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Release Version Parity & Readiness (`\(badge)`)",
            "",
            "- **CFBundleShortVersionString**: `\(shortVersionString)`",
            "- **CFBundleVersion**: `\(bundleVersion)`",
            "- **CLI Router Version**: `\(cliRouterVersion)`",
            "- **Recommended Next SemVer**: `\(nextSuggestedVersion)` (`\(bumpLevel.rawValue)`)",
        ]
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

public enum ReleaseChangelogEngine {
    /// Parses lines formatted as `<sha>|<subject>` (or plain `<subject>`) into `ChangelogCommitEntry` items,
    /// skipping automated `Merge pull request` or `Merge branch` commits.
    public static func parseLogLines(_ lines: [String]) -> [ChangelogCommitEntry] {
        var entries: [ChangelogCommitEntry] = []

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let sha: String
            let subject: String
            if let pipeIndex = trimmed.firstIndex(of: "|") {
                sha = String(trimmed[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                subject = String(trimmed[trimmed.index(after: pipeIndex)...]).trimmingCharacters(in: .whitespaces)
            } else {
                sha = "HEAD"
                subject = trimmed
            }

            if subject.hasPrefix("Merge pull request") || subject.hasPrefix("Merge branch") {
                continue
            }

            entries.append(parseSubject(sha: sha, subject: subject))
        }
        return entries
    }

    /// Parses a single Conventional Commit subject header.
    public static func parseSubject(sha: String, subject: String) -> ChangelogCommitEntry {
        guard let colonIndex = subject.firstIndex(of: ":") else {
            return ChangelogCommitEntry(
                sha: sha,
                type: "other",
                scope: nil,
                isBreaking: subject.contains("BREAKING CHANGE"),
                summary: subject
            )
        }

        let prefix = String(subject[..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let summary = String(subject[subject.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        let isBreaking = prefix.hasSuffix("!") || subject.contains("BREAKING CHANGE")
        let cleanPrefix = isBreaking && prefix.hasSuffix("!") ? String(prefix.dropLast()) : prefix

        if let openParen = cleanPrefix.firstIndex(of: "("),
           cleanPrefix.hasSuffix(")") {
            let type = String(cleanPrefix[..<openParen]).lowercased()
            let scopeStart = cleanPrefix.index(after: openParen)
            let scopeEnd = cleanPrefix.index(before: cleanPrefix.endIndex)
            let scope = scopeStart < scopeEnd ? String(cleanPrefix[scopeStart..<scopeEnd]) : nil
            return ChangelogCommitEntry(
                sha: sha,
                type: type,
                scope: scope,
                isBreaking: isBreaking,
                summary: summary.isEmpty ? subject : summary
            )
        }

        return ChangelogCommitEntry(
            sha: sha,
            type: cleanPrefix.lowercased(),
            scope: nil,
            isBreaking: isBreaking,
            summary: summary.isEmpty ? subject : summary
        )
    }

    /// Calculates the required Semantic Version bump level and resulting version from a list of commits.
    public static func calculateNextVersion(
        from baseVersion: SemanticVersion,
        commits: [ChangelogCommitEntry]
    ) -> (version: SemanticVersion, bump: SemVerBumpLevel) {
        if commits.isEmpty {
            return (baseVersion, .none)
        }
        if commits.contains(where: { $0.isBreaking }) {
            return (SemanticVersion(major: baseVersion.major + 1, minor: 0, patch: 0), .major)
        }
        if commits.contains(where: { $0.type == "feat" }) {
            return (SemanticVersion(major: baseVersion.major, minor: baseVersion.minor + 1, patch: 0), .minor)
        }
        return (SemanticVersion(major: baseVersion.major, minor: baseVersion.minor, patch: baseVersion.patch + 1), .patch)
    }

    /// Renders a structured Keep-a-Changelog / GitHub Release Notes Markdown document.
    public static func renderReleaseNotes(
        version: String,
        dateString: String = "2026-10-08",
        commits: [ChangelogCommitEntry]
    ) -> String {
        var lines: [String] = [
            "# Release v\(version) (\(dateString))",
            "",
        ]

        let breaking = commits.filter { $0.isBreaking }
        let security = commits.filter { !$0.isBreaking && ($0.type == "security" || $0.scope == "security") }
        let features = commits.filter { !$0.isBreaking && $0.type == "feat" && $0.scope != "security" }
        let fixesAndPerf = commits.filter { !$0.isBreaking && ($0.type == "fix" || $0.type == "perf") && $0.scope != "security" }
        let toolingAndCI = commits.filter {
            !$0.isBreaking
                && $0.type != "security"
                && $0.scope != "security"
                && $0.type != "feat"
                && $0.type != "fix"
                && $0.type != "perf"
        }

        func appendSection(title: String, items: [ChangelogCommitEntry]) {
            guard !items.isEmpty else { return }
            lines.append("### \(title)")
            for item in items {
                let scopeTag = item.scope.map { "**\($0)**: " } ?? ""
                lines.append("- \(scopeTag)\(item.summary) (`\(item.sha)`)")
            }
            lines.append("")
        }

        appendSection(title: "Breaking Changes", items: breaking)
        appendSection(title: "Features", items: features)
        appendSection(title: "Security & Supply Chain", items: security)
        appendSection(title: "Bug Fixes & Performance", items: fixesAndPerf)
        appendSection(title: "CI/CD, CLI & Tooling", items: toolingAndCI)

        if commits.isEmpty {
            lines.append("_No user-facing changes recorded in this range._")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Audits `ApexAgent/Info.plist` and `project.yml` version parity and computes the next version from recent commits.
    public static func auditReleaseReadiness(
        atRepoRoot rootURL: URL,
        recentCommits: [ChangelogCommitEntry]? = nil
    ) -> ReleaseVersionParityReport {
        var findings: [String] = []
        let infoPlistURL = rootURL.appendingPathComponent("ApexAgent/Info.plist")
        var shortVersion = ""
        var bundleVersion = ""

        if let data = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            shortVersion = (plist["CFBundleShortVersionString"] as? String) ?? ""
            bundleVersion = (plist["CFBundleVersion"] as? String) ?? ""
        } else {
            findings.append("Unable to parse ApexAgent/Info.plist.")
        }

        if SemanticVersion(parsing: shortVersion) == nil {
            findings.append("CFBundleShortVersionString ('\(shortVersion)') is not a valid X.Y or X.Y.Z semantic version.")
        }

        if Int(bundleVersion) == nil || (Int(bundleVersion) ?? 0) <= 0 {
            findings.append("CFBundleVersion ('\(bundleVersion)') must be a positive integer build number.")
        }

        if SemanticVersion(parsing: ApexCLIRouter.appVersion) == nil {
            findings.append("ApexCLIRouter.appVersion ('\(ApexCLIRouter.appVersion)') is not a valid semantic version.")
        }

        // Check project.yml if it declares an explicit literal MARKETING_VERSION
        let projectYMLURL = rootURL.appendingPathComponent("project.yml")
        if let projectYML = try? String(contentsOf: projectYMLURL, encoding: .utf8) {
            for line in projectYML.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("MARKETING_VERSION:") {
                    let value = trimmed.replacingOccurrences(of: "MARKETING_VERSION:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !value.isEmpty && !value.hasPrefix("$(") && value != shortVersion {
                        findings.append(
                            "project.yml MARKETING_VERSION ('\(value)') does not match Info.plist CFBundleShortVersionString ('\(shortVersion)')."
                        )
                    }
                }
            }
        }

        let commits = recentCommits ?? loadRecentGitCommits(atRepoRoot: rootURL, limit: 25)
        let baseSemVer = SemanticVersion(parsing: ApexCLIRouter.appVersion)
            ?? SemanticVersion(parsing: shortVersion)
            ?? SemanticVersion(major: 1, minor: 0, patch: 0)
        let (nextVer, bump) = calculateNextVersion(from: baseSemVer, commits: commits)

        return ReleaseVersionParityReport(
            passed: findings.isEmpty,
            shortVersionString: shortVersion,
            bundleVersion: bundleVersion,
            cliRouterVersion: ApexCLIRouter.appVersion,
            nextSuggestedVersion: nextVer.description,
            bumpLevel: bump,
            findings: findings
        )
    }

    /// Reads the most recent git commit subjects from `rootURL` (up to `limit`).
    public static func loadRecentGitCommits(atRepoRoot rootURL: URL, limit: Int = 25) -> [ChangelogCommitEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path, "log", "-n", "\(max(1, limit))", "--pretty=format:%h|%s"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return parseLogLines(text.components(separatedBy: .newlines))
        } catch {
            return []
        }
    }
}
