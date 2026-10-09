import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 81 — MCPKit Wire Protocol JSON-RPC & Backpressure Gate Tests")
struct MCPWireProtocolAuditorTests {

    @Test("Valid JSON-RPC 2.0 tool call request passes audit with 100% score")
    func validToolCallRequestPasses() {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 42,
            "method": "tools/call",
            "params": {
                "name": "read_file",
                "arguments": { "path": "/tmp/test.txt" }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let report = MCPWireProtocolAuditor.auditRawFrame(data)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.messageKind == .request)
        #expect(report.jsonrpcValid)
        #expect(report.methodAllowed)
        #expect(report.violations.isEmpty)
    }

    @Test("Valid JSON-RPC 2.0 notification passes audit")
    func validNotificationPasses() {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }
        """
        let data = json.data(using: .utf8)!
        let report = MCPWireProtocolAuditor.auditRawFrame(data)

        #expect(report.passed)
        #expect(report.messageKind == .notification)
        #expect(report.jsonrpcValid)
        #expect(report.methodAllowed)
    }

    @Test("Response containing both result and error triggers mutual exclusion violation")
    func responseMutualExclusionViolation() {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": { "status": "ok" },
            "error": { "code": -32603, "message": "Internal error" }
        }
        """
        let data = json.data(using: .utf8)!
        let report = MCPWireProtocolAuditor.auditRawFrame(data)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_RESPONSE_MUTUAL_EXCLUSION" })
    }

    @Test("Missing or invalid jsonrpc version triggers INVALID_JSONRPC_VERSION")
    func invalidVersionFails() {
        let json = """
        {
            "jsonrpc": "1.0",
            "id": 1,
            "method": "ping"
        }
        """
        let data = json.data(using: .utf8)!
        let report = MCPWireProtocolAuditor.auditRawFrame(data)

        #expect(!report.passed)
        #expect(!report.jsonrpcValid)
        #expect(report.violations.contains { $0.code == "INVALID_JSONRPC_VERSION" })
    }

    @Test("Chunk defragmentation correctly reassembles split newline-delimited frames")
    func chunkDefragmentationReassemblesFrames() {
        let chunk1 = "{\"jsonrpc\":\"2.0\",\"id\":1,".data(using: .utf8)!
        let chunk2 = "\"method\":\"ping\"}\n{\"jsonrpc\":\"2.0\",\"method\":".data(using: .utf8)!
        let chunk3 = "\"notifications/initialized\"}\n".data(using: .utf8)!

        let frames = MCPWireProtocolAuditor.defragmentChunks(chunks: [chunk1, chunk2, chunk3])
        #expect(frames.count == 2)

        let frame1String = String(data: frames[0], encoding: .utf8)
        let frame2String = String(data: frames[1], encoding: .utf8)

        #expect(frame1String == "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")
        #expect(frame2String == "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
    }

    @Test("Backpressure auditor enforces maximum in-flight requests")
    func backpressureEnforcesCap() {
        let config = MCPWireProtocolConfig(maxInFlightRequests: 16)
        #expect(MCPWireProtocolAuditor.auditInFlightRequests(currentCount: 10, config: config))
        #expect(MCPWireProtocolAuditor.auditInFlightRequests(currentCount: 16, config: config))
        #expect(!MCPWireProtocolAuditor.auditInFlightRequests(currentCount: 17, config: config))
    }
}
