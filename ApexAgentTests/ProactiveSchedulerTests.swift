import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Markdown projection for proactive findings

@Suite("ProactiveFindingMarkdownTests")
struct ProactiveFindingMarkdownTests {
    @Test @MainActor func proactiveFindingMarkdown() {
        let f = ProactiveScheduler.ProactiveFinding(title: "T", detail: "D", severity: .warning)
        let md = f.formatAsMarkdown()
        #expect(md.contains("Warning"))
    }
}
