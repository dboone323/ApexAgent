import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 37 — Git Hook Suite (pre-commit, commit-msg) & Staged Diff Gate Tests")
struct GitHookGateTests {

    @Test("validateCommitMessage accepts Conventional Commits, scopes, breaking !, and Merge/Revert headers")
    func validatesConventionalCommitMessages() {
        let featScoped = GitHookGate.validateCommitMessage("""
        # Please enter the commit message for your changes.
        feat(security): add DependencyLockAuditor for supply-chain pin verification

        Detailed body paragraph.
        """)
        #expect(featScoped.passed)
        #expect(featScoped.commitType == "feat")
        #expect(featScoped.scope == "security")
        #expect(!featScoped.isBreakingChange)
        #expect(featScoped.errors.isEmpty)

        let breakingFix = GitHookGate.validateCommitMessage("fix(mcp)!: drop legacy 2023 protocol")
        #expect(breakingFix.passed)
        #expect(breakingFix.commitType == "fix")
        #expect(breakingFix.scope == "mcp")
        #expect(breakingFix.isBreakingChange)

        let mergeCommit = GitHookGate.validateCommitMessage("Merge pull request #9 from dboone323/feat/loop-4")
        #expect(mergeCommit.passed)
        #expect(mergeCommit.commitType == "merge")
    }

    @Test("validateCommitMessage rejects empty, malformed, unknown-type, or overlong commit headers")
    func rejectsInvalidCommitMessages() {
        let empty = GitHookGate.validateCommitMessage("# only comments\n   \n")
        #expect(!empty.passed)

        let badType = GitHookGate.validateCommitMessage("wip(ui): half-baked experiment")
        #expect(!badType.passed)
        #expect(badType.errors.contains { $0.contains("Unsupported commit type 'wip'") })

        let missingColon = GitHookGate.validateCommitMessage("Added new feature without prefix")
        #expect(!missingColon.passed)

        let tooShort = GitHookGate.validateCommitMessage("fix: ok")
        #expect(!tooShort.passed)

        let overlong = GitHookGate.validateCommitMessage("feat: " + String(repeating: "a", count: 130))
        #expect(!overlong.passed)
        #expect(overlong.errors.contains { $0.contains("exceeds 120 characters") })
    }

    @Test("validateStagedFiles blocks forbidden artifacts, oversized files, secrets, and conflict markers")
    func validatesStagedFilesInPreCommitGate() {
        let cleanReport = GitHookGate.validateStagedFiles([
            (path: "ApexAgent/Models/GitHookGate.swift", byteSize: 4096, content: "import Foundation\npublic enum Clean {}\n")
        ])
        #expect(cleanReport.passed)
        #expect(cleanReport.violations.isEmpty)
        #expect(cleanReport.formatSummary().hasPrefix("PASS:"))

        let synthSecret = "ghp_" + String(repeating: "B", count: 36)
        let synthConflict = String(repeating: "<", count: 7) + " HEAD\nlet x = 1\n"
        let dirtyReport = GitHookGate.validateStagedFiles([
            (path: "ApexAgent/.DS_Store", byteSize: 6148, content: nil),
            (path: "build/Test.xcresult/Info.plist", byteSize: 1024, content: nil),
            (path: "Assets/HugeVideo.mov", byteSize: 8 * 1024 * 1024, content: nil),
            (path: "ApexAgent/Leaked.swift", byteSize: 200, content: "let pat = \"\(synthSecret)\""),
            (path: "ApexAgent/Conflicted.swift", byteSize: 200, content: synthConflict)
        ])

        #expect(!dirtyReport.passed)
        #expect(dirtyReport.violations.contains { $0.kind == .forbiddenArtifactPath && $0.path == "ApexAgent/.DS_Store" })
        #expect(dirtyReport.violations.contains { $0.kind == .forbiddenArtifactPath && $0.path.contains(".xcresult") })
        #expect(dirtyReport.violations.contains { $0.kind == .oversizedFile && $0.path == "Assets/HugeVideo.mov" })
        #expect(dirtyReport.violations.contains { $0.kind == .leakedSecretInStagedContent && $0.path == "ApexAgent/Leaked.swift" })
        #expect(dirtyReport.violations.contains { $0.kind == .mergeConflictMarkerInStagedContent && $0.path == "ApexAgent/Conflicted.swift" })
    }
}
