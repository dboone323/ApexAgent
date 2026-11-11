import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("ApexWorkflowsExpansionTests")
struct ApexWorkflowsExpansionTests {

    @Test("Workflows 11 through 70 execute real subsystems and pass")
    func workflows11Through70Pass() async {
        let ids: Set<Int> = Set(11...70)
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 60)

        for id in 11...70 {
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
        let results = await ApexWorkflows.run(ids: [11, 21, 26, 30, 31, 35, 40, 45, 50, 55, 60, 65, 70])
        let jsonString = ApexWorkflows.formatJSON(results)
        let data = try #require(jsonString.data(using: .utf8))
        let decoded = try JSONDecoder().decode([WorkflowResult].self, from: data)
        #expect(decoded == results)
        #expect(decoded.allSatisfy { $0.passed })
    }

    @Test("Workflow catalog descriptors and Markdown export cover all 70 workflows")
    func catalogAndMarkdownExportCoverAll70Workflows() {
        let descriptors = ApexWorkflows.allDescriptors()
        #expect(descriptors.count >= 70)
        #expect(descriptors.prefix(70).map(\.id) == Array(1...70))

        let markdown = ApexWorkflows.exportWorkflowsCatalogMarkdown()
        #expect(markdown.contains("### ⚙️ Autonomous Local Workflows Catalog (\(descriptors.count) workflows)"))
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
        #expect(markdown.contains("Headless browser automation URL scheme, domain allowlist & SSRF defense gate"))
        #expect(markdown.contains("Visual perception dHash difference calculation & dirty rect bounds gate"))
        #expect(markdown.contains("Xcode simulator simctl lifecycle transition & injection defense gate"))
        #expect(markdown.contains("AppleScript OSA AST compilation & admin privilege execution gate"))
        #expect(markdown.contains("Personal productivity email CRLF injection & calendar bounds gate"))
        #expect(markdown.contains("Companion device mutual TLS & ephemeral PIN pairing gate"))
        #expect(markdown.contains("Multi-agent swarm worker priority scheduling & concurrency throttling gate"))
        #expect(markdown.contains("Agent turn watchdog step-level deadline & runaway loop gate"))
        #expect(markdown.contains("Unified 12-check ApexAgent Doctor subsystem health matrix gate"))
        #expect(markdown.contains("Centurion Milestone: 100-Batch autonomous hardening loop verification & 70-workflow catalog audit"))
    }

    @Test("ApexWorkflows.run executes nonisolated workflows concurrently and preserves ordered results")
    func concurrentWorkflowExecutionPreservesOrderedResults() async {
        let ids: Set<Int> = [11, 16, 21, 26, 31, 35, 41, 51, 61, 71, 81, 91]
        let results = await ApexWorkflows.run(ids: ids)
        #expect(results.count == 12)
        #expect(results.allSatisfy { $0.passed })
        #expect(results.map(\.id) == [11, 16, 21, 26, 31, 35, 41, 51, 61, 71, 81, 91])
    }
}
