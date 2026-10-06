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
