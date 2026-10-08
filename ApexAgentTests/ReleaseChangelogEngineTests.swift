import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Release Changelog Engine & SemVer Parity Tests (Batch 43)")
struct ReleaseChangelogEngineTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Parses Conventional Commit log lines, skips merge commits, and computes SemVer bumps")
    func parsesConventionalCommitsAndComputesSemVerBumps() {
        let logLines = [
            "33953a9|Merge pull request #10 from dboone323/feat/autonomous-hardening-loop-5",
            "98b1a99|feat(security): add DependencyLockAuditor for supply-chain pin verification",
            "4705125|feat(ci): add GitHookGate for Conventional Commits",
            "1122334|fix(gateway): resolve WebSocket reconnect jitter",
            "aabbccd|perf(scheduler): coalesce low-priority timer wakeups",
        ]

        let entries = ReleaseChangelogEngine.parseLogLines(logLines)
        #expect(entries.count == 4)
        #expect(entries[0].type == "feat")
        #expect(entries[0].scope == "security")
        #expect(!entries[0].isBreaking)

        let base = SemanticVersion(major: 2026, minor: 10, patch: 0)
        let (minorBumpVer, minorLevel) = ReleaseChangelogEngine.calculateNextVersion(from: base, commits: entries)
        #expect(minorLevel == .minor)
        #expect(minorBumpVer == SemanticVersion(major: 2026, minor: 11, patch: 0))

        // Patch-only commits
        let patchOnly = Array(entries.suffix(2))
        let (patchVer, patchLevel) = ReleaseChangelogEngine.calculateNextVersion(from: base, commits: patchOnly)
        #expect(patchLevel == .patch)
        #expect(patchVer == SemanticVersion(major: 2026, minor: 10, patch: 1))

        // Breaking change commit triggers major bump
        let breakingEntries = ReleaseChangelogEngine.parseLogLines([
            "deadbee|feat(api)!: drop legacy v1 RPC frame format"
        ])
        let (majorVer, majorLevel) = ReleaseChangelogEngine.calculateNextVersion(from: base, commits: breakingEntries)
        #expect(majorLevel == .major)
        #expect(majorVer == SemanticVersion(major: 2027, minor: 0, patch: 0))

        // Render categorized Markdown release notes
        let notes = ReleaseChangelogEngine.renderReleaseNotes(
            version: minorBumpVer.description,
            dateString: "2026-10-08",
            commits: entries
        )
        #expect(notes.contains("# Release v2026.11.0 (2026-10-08)"))
        #expect(notes.contains("### Features"))
        #expect(notes.contains("### Security & Supply Chain"))
        #expect(notes.contains("### Bug Fixes & Performance"))
    }

    @Test("Audits live repository Info.plist and project.yml version parity")
    func auditsLiveRepositoryReleaseReadiness() {
        let report = ReleaseChangelogEngine.auditReleaseReadiness(atRepoRoot: repoRootURL)
        #expect(report.passed, "Findings: \(report.findings)")
        #expect(report.shortVersionString == "1.0")
        #expect(report.bundleVersion == "1")
        #expect(report.toMarkdown().contains("Release Version Parity & Readiness (`PASS`)"))
    }

    @Test("ApexCLIRouter parses and renders changelog and release-check subcommands")
    @MainActor
    func cliRouterParsesAndRendersChangelogAndReleaseCheck() throws {
        let parsedChangelog = try ApexCLIRouter.parse(arguments: ["ApexAgent", "changelog"])
        #expect(parsedChangelog.command == .changelog(jsonOutput: false))

        let parsedReleaseCheck = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "release-check"])
        #expect(parsedReleaseCheck.command == .releaseCheck(jsonOutput: true))

        let changelogResult = try #require(ApexCLIRouter.renderImmediateSubcommand(.changelog(jsonOutput: false)))
        #expect(changelogResult.exitCode == 0)
        #expect(changelogResult.output.contains("# Release v"))

        let releaseCheckResult = try #require(ApexCLIRouter.renderImmediateSubcommand(.releaseCheck(jsonOutput: true)))
        #expect(releaseCheckResult.exitCode == 0)
        let decoded = try JSONDecoder().decode(ReleaseVersionParityReport.self, from: Data(releaseCheckResult.output.utf8))
        #expect(decoded.passed)
    }
}
