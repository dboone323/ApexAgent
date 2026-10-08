import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 15 execute real subsystems and pass")
    func workflows11Through15Pass() async {
        let ids: Set<Int> = [11, 12, 13, 14, 15]
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 5)

        for id in [11, 12, 13, 14, 15] {
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
        let results = await ApexWorkflows.run(ids: [11, 13, 15])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 15 workflows")
    func catalogAndMarkdownExportCover15Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count == 15)
        #expect(descriptors.map(\.id) == Array(1...15))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (15 workflows)"))
        #expect(markdown.contains("Pre-push security & hygiene self-audit"))
        #expect(markdown.contains("Persistence corruption quarantine & recovery"))
        #expect(markdown.contains("MCP 2026-07-28 negotiation & W3C traceparent"))
        #expect(markdown.contains("Deep-link routing + Spotlight handoff"))
        #expect(markdown.contains("TickerScheduler coalescing & doctor health check"))
    }
}
