import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 40 execute real subsystems and pass")
    func workflows11Through40Pass() async {
        let ids: Set<Int> = Set(11...40)
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 30)

        for id in 11...40 {
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
        let results = await ApexWorkflows.run(ids: [11, 21, 26, 30, 31, 35, 40])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 40 workflows")
    func catalogAndMarkdownExportCoverAll40Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count == 40)
        #expect(descriptors.map(\.id) == Array(1...40))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (40 workflows)"))
        #expect(markdown.contains("Pre-push security & hygiene self-audit"))
        #expect(markdown.contains("SARIF v2.1.0 security & static analysis report export"))
        #expect(markdown.contains("Xcode .xctestplan timeout & coverage target audit"))
        #expect(markdown.contains("Workspace source complexity & asset footprint gate"))
        #expect(markdown.contains("CLI subcommand contract & JSON smoke-test matrix"))
        #expect(markdown.contains("Full 10-check ApexAgent Doctor subsystem verification"))
        #expect(markdown.contains("OpenTelemetry & W3C trace context exporter validation"))
        #expect(markdown.contains("MCP tool permissions & host sandboxing security gate"))
        #expect(markdown.contains("Apple Virtualization & OCI container isolation policy auditor"))
        #expect(markdown.contains("Collaborative mesh authentication & P2P grant rate-limiting gate"))
        #expect(markdown.contains("Cognitive memory compaction & semantic vector integrity gate"))
        #expect(markdown.contains("Spotlight search contract & index attribute integrity auditor"))
        #expect(markdown.contains("MetricKit telemetry anonymization & signed crash report packaging"))
        #expect(markdown.contains("Deep-link action dispatcher & URL scheme route gate"))
        #expect(markdown.contains("Ten-check unified subsystem doctor diagnostic verification"))
        #expect(markdown.contains("Full-system multi-subsystem resilience audit"))
    }
}
