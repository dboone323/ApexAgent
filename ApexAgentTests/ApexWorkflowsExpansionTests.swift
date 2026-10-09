import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 60 execute real subsystems and pass")
    func workflows11Through60Pass() async {
        let ids: Set<Int> = Set(11...60)
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 50)

        for id in 11...60 {
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
        let results = await ApexWorkflows.run(ids: [11, 21, 26, 30, 31, 35, 40, 45, 50, 55, 60])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 60 workflows")
    func catalogAndMarkdownExportCoverAll60Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count == 60)
        #expect(descriptors.map(\.id) == Array(1...60))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (60 workflows)"))
        #expect(markdown.contains("Pre-push security & hygiene self-audit"))
        #expect(markdown.contains("SARIF v2.1.0 security & static analysis report export"))
        #expect(markdown.contains("Xcode .xctestplan timeout & coverage target audit"))
        #expect(markdown.contains("Workspace source complexity & asset footprint gate"))
        #expect(markdown.contains("CLI subcommand contract & JSON smoke-test matrix"))
        #expect(markdown.contains("Full 11-check ApexAgent Doctor subsystem verification"))
        #expect(markdown.contains("OpenTelemetry & W3C trace context exporter validation"))
        #expect(markdown.contains("MCP tool permissions & host sandboxing security gate"))
        #expect(markdown.contains("Apple Virtualization & OCI container isolation policy auditor"))
        #expect(markdown.contains("Collaborative mesh authentication & P2P grant rate-limiting gate"))
        #expect(markdown.contains("Cognitive memory compaction & semantic vector integrity gate"))
        #expect(markdown.contains("Spotlight search contract & index attribute integrity auditor"))
        #expect(markdown.contains("MetricKit telemetry anonymization & signed crash report packaging"))
        #expect(markdown.contains("Deep-link action dispatcher & URL scheme route gate"))
        #expect(markdown.contains("Eleven-check unified subsystem doctor diagnostic verification"))
        #expect(markdown.contains("Full-system multi-subsystem resilience audit"))
        #expect(markdown.contains("Tool execution safety sandbox & workspace containment gate"))
        #expect(markdown.contains("Model provider fault-tolerant circuit breaker & failover gate"))
        #expect(markdown.contains("App Intents schema & Siri Shortcuts parameter sanitization audit"))
        #expect(markdown.contains("Companion camera & sensor privacy consent & coordinate coarsening gate"))
        #expect(markdown.contains("Multi-agent session coordination & deadlock cycle detection gate"))
        #expect(markdown.contains("Accessibility Omni-Targeter & Screen perception coordinate normalization audit"))
        #expect(markdown.contains("SwiftData SQLite store header magic bytes, permission & checksum audit"))
        #expect(markdown.contains("Network diagnostics host reachability & SSRF metadata protection gate"))
        #expect(markdown.contains("Multi-subsystem security policy audit & sandbox compliance verification"))
        #expect(markdown.contains("MCPKit wire protocol framing & message integrity gate"))
        #expect(markdown.contains("SharedContainer cross-process task queue state machine gate"))
        #expect(markdown.contains("On-device MLX & local LLM memory pressure & sampling gate"))
        #expect(markdown.contains("Local retrieval index vector parity, norms & chunking gate"))
        #expect(markdown.contains("Multi-agent playbook execution graph, cycles & rollback gate"))
        #expect(markdown.contains("Ghost cursor & screen highlight overlay geometry clamp gate"))
        #expect(markdown.contains("File patch tool fuzzy chunk & CRLF newline gate"))
        #expect(markdown.contains("Application control tool PID liveness & AppleScript gate"))
        #expect(markdown.contains("System diagnostics OSLog query predicate & masking gate"))
        #expect(markdown.contains("Autonomous workflow milestone 60 & complete hardening loop 11 audit"))
    }
}
