import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 25 execute real subsystems and pass")
    func workflows11Through25Pass() async {
        let ids: Set<Int> = Set(11...25)
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 15)

        for id in 11...25 {
            guard let result = results.first(where: { $0.id == id }) else {
                Issue.record("Missing workflow result for ID \(id)")
                continue
            }
            #expect(result.passed, "Workflow \(id) failed: \(result.line)")
            #expect(!result.evidence.isEmpty)
            #expect(result.line.hasPrefix("PASS [\(id)]"))
        }
    }

    @Test("formatJSON serializes and round-trips WorkflowResult array")
    func formatJSONRoundTripsWorkflowResults() async throws {
        let results = await ApexWorkflows.run(ids: [11, 16, 21, 25])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 25 workflows")
    func catalogAndMarkdownExportCover15Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count == 25)
        #expect(descriptors.map(\.id) == Array(1...25))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (25 workflows)"))
        #expect(markdown.contains("Pre-push security & hygiene self-audit"))
        #expect(markdown.contains("Code coverage threshold & changed-file diff gate"))
        #expect(markdown.contains("Privacy manifest & Required-Reason API drift audit"))
        #expect(markdown.contains("Conventional Changelog & SemVer bump calculator"))
        #expect(markdown.contains("Release version parity & readiness gate"))
        #expect(markdown.contains("SLSA v1.0 build provenance & notarization verification"))
    }
}
