import Foundation
import Testing
@testable import ApexAgentCore

@Suite("MCP Policy Auditor Security Tests")
struct MCPPolicyAuditorTests {
    @Test("Audits compliant server with zero violations and full score")
    func compliantServerAudit() {
        let server = MCPServerConfig(
            name: "Safe Project Filesystem",
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/developer/Developer/ApexAgent"],
            transport: "stdio"
        )

        let report = MCPPolicyAuditor.audit(servers: [server])
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.evaluatedServers == 1)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("100.0/100.0"))
    }

    @Test("Detects unconstrained shell binary execution")
    func unconstrainedShellAudit() {
        let server = MCPServerConfig(
            name: "Dangerous Shell Server",
            command: "/bin/bash",
            arguments: ["-c", "rm -rf /tmp/data"],
            transport: "stdio"
        )

        let report = MCPPolicyAuditor.audit(servers: [server])
        #expect(!report.passed)
        #expect(report.score < 50.0)
        let hasShellViolation = report.violations.contains { $0.ruleId == "mcp_unconstrained_shell" }
        #expect(hasShellViolation)
        let hasEvalViolation = report.violations.contains { $0.ruleId == "mcp_inline_eval_argument" }
        #expect(hasEvalViolation)
    }

    @Test("Detects insecure cleartext remote transport")
    func insecureRemoteTransportAudit() {
        let server = MCPServerConfig(
            name: "Remote Insecure MCP",
            command: "mcp-proxy",
            arguments: [],
            transport: "sse",
            endpointURL: "http://api.external-untrusted.org/mcp/sse"
        )

        let report = MCPPolicyAuditor.audit(servers: [server])
        #expect(!report.passed)
        let hasTransportViolation = report.violations.contains { $0.ruleId == "mcp_insecure_transport_scheme" }
        #expect(hasTransportViolation)
    }

    @Test("Permits local loopback HTTP endpoint")
    func localLoopbackHTTPAudit() {
        let server = MCPServerConfig(
            name: "Local Dev MCP",
            command: "local-proxy",
            arguments: [],
            transport: "sse",
            endpointURL: "http://localhost:8080/mcp"
        )

        let violations = MCPPolicyAuditor.auditServer(server)
        let hasInsecure = violations.contains { $0.ruleId == "mcp_insecure_transport_scheme" }
        #expect(!hasInsecure)
    }

    @Test("Detects root filesystem mount and sensitive path exposure")
    func sensitivePathExposureAudit() {
        let server1 = MCPServerConfig(
            name: "Root Mount Server",
            command: "fs-mcp",
            arguments: ["/"]
        )
        let server2 = MCPServerConfig(
            name: "SSH Key Exposer",
            command: "fs-mcp",
            arguments: ["~/.ssh"]
        )

        let report = MCPPolicyAuditor.audit(servers: [server1, server2])
        #expect(!report.passed)
        #expect(report.evaluatedServers == 2)

        let rootViolation = report.violations.contains { $0.ruleId == "mcp_root_filesystem_mount" }
        #expect(rootViolation)

        let sshViolation = report.violations.contains { $0.ruleId == "mcp_sensitive_path_exposure" }
        #expect(sshViolation)
    }

    @Test("Detects empty executable command")
    func emptyCommandAudit() {
        let server = MCPServerConfig(
            name: "Blank Command Server",
            command: "   ",
            arguments: []
        )

        let report = MCPPolicyAuditor.audit(servers: [server])
        #expect(!report.passed)
        let emptyViolation = report.violations.contains { $0.ruleId == "mcp_empty_command" }
        #expect(emptyViolation)
    }
}
