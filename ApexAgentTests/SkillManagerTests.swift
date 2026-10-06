import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Markdown projection for skill manifests

@Suite("SkillManifestMarkdownTests")
struct SkillManifestMarkdownTests {
    @Test func skillManifestMarkdown() {
        let info = SkillManifestInfo(name: "demo", description: "Does things", scriptPath: "/tmp/x.sh", parameterCount: 2)
        let md = info.formatAsMarkdown()
        #expect(md.contains("demo"))
    }
}

// MARK: - Skill validation badges & manifest preflight

@Suite("SkillValidationGuardTests")
struct SkillValidationGuardTests {
    @Test func skillValidationBadges() {
        #expect(SkillValidationError.fileNotFound("x").badge.contains("Missing"))
        #expect(SkillValidationError.invalidJSON("x").formatAsMarkdown().contains("Bad JSON"))
    }

    @Test func skillManifestPreflight() {
        let ok = SkillManifestInfo(name: "n", description: "d", scriptPath: "/tmp/x.sh", parameterCount: 1)
        #expect(ok.preflightError() == nil)
        #expect(ok.isPreflightClean)
        let bad = SkillManifestInfo(name: "", description: "", scriptPath: "", parameterCount: -1)
        #expect(bad.preflightError() != nil)
        #expect(!bad.isPreflightClean)
    }
}
