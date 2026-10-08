import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 30 execute real subsystems and pass")
    func workflows11Through30Pass() async {
        let ids: Set<Int> = Set(11...30)
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 20)

        for id in 11...30 {
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
        let results = await ApexWorkflows.run(ids: [11, 21, 26, 30])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 30 workflows")
    func catalogAndMarkdownExportCover15Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count == 30)
        #expect(descriptors.map(\.id) == Array(1...30))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (30 workflows)"))
        #expect(markdown.contains("Pre-push security & hygiene self-audit"))
        #expect(markdown.contains("SARIF v2.1.0 security & static analysis report export"))
        #expect(markdown.contains("Xcode .xctestplan timeout & coverage target audit"))
        #expect(markdown.contains("Workspace source complexity & asset footprint gate"))
        #expect(markdown.contains("CLI subcommand contract & JSON smoke-test matrix"))
        #expect(markdown.contains("Full 9-check ApexAgent Doctor subsystem verification"))
    }
}
