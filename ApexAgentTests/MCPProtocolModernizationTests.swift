import Testing
import Foundation
@testable import ApexAgentCore

@Suite("MCPProtocolModernizationTests", .serialized)
struct MCPProtocolModernizationTests {

    @Test("Version negotiation resolves 2026-07-28, 2025-03-26, 2024-11-05, and falls back for unknown versions")
    func versionNegotiationMatrix() throws {
        #expect(MCPProtocolVersion.latestSupported == "2026-07-28")
        #expect(MCPProtocolVersion.legacyFallback == "2024-11-05")

        #expect(
            MCPProtocolVersion.resolveNegotiatedVersion(
                advertised: "2026-07-28",
                serverResponseVersion: "2026-07-28"
            ) == "2026-07-28"
        )
        #expect(
            MCPProtocolVersion.resolveNegotiatedVersion(
                advertised: "2026-07-28",
                serverResponseVersion: "2025-03-26"
            ) == "2025-03-26"
        )
        #expect(
            MCPProtocolVersion.resolveNegotiatedVersion(
                advertised: "2026-07-28",
                serverResponseVersion: "2024-11-05"
            ) == "2024-11-05"
        )
        #expect(
            MCPProtocolVersion.resolveNegotiatedVersion(
                advertised: "2026-07-28",
                serverResponseVersion: "2023-01-01"
            ) == "2024-11-05"
        )
        #expect(
            MCPProtocolVersion.resolveNegotiatedVersion(
                advertised: "2026-07-28",
                serverResponseVersion: nil
            ) == "2024-11-05"
        )

        // Decode real initialize response JSON fixtures for 2026-07-28 and 2024-11-05
        let modernFixture = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "protocolVersion": "2026-07-28",
            "capabilities": { "tools": { "listChanged": true } },
            "serverInfo": { "name": "modern-mcp", "version": "2.1.0" }
          }
        }
        """.data(using: .utf8)!

        let legacyFixture = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": { "tools": {} },
            "serverInfo": { "name": "legacy-stdio-mcp", "version": "0.6.2" }
          }
        }
        """.data(using: .utf8)!

        let modernDecoded = try JSONDecoder().decode(JSONRPCResponse<MCPClient.InitializeResult>.self, from: modernFixture)
        #expect(modernDecoded.result?.protocolVersion == "2026-07-28")

        let legacyDecoded = try JSONDecoder().decode(JSONRPCResponse<MCPClient.InitializeResult>.self, from: legacyFixture)
        #expect(legacyDecoded.result?.protocolVersion == "2024-11-05")
    }

    @Test("Tool annotations parse readOnlyHint and destructiveHint and surface into DynamicToolbox policy")
    @MainActor
    func toolAnnotationsParsingAndDynamicToolboxPolicy() throws {
        let toolsListJSON = """
        {
          "jsonrpc": "2.0",
          "id": 2,
          "result": {
            "tools": [
              {
                "name": "read_file",
                "description": "Reads a file from disk without modifying state",
                "inputSchema": {
                  "type": "object",
                  "properties": {
                    "path": { "type": "string", "description": "File path" }
                  },
                  "required": ["path"]
                },
                "annotations": {
                  "title": "Read File Contents",
                  "readOnlyHint": true,
                  "destructiveHint": false,
                  "idempotentHint": true,
                  "openWorldHint": false
                }
              },
              {
                "name": "delete_directory",
                "description": "Recursively deletes a directory",
                "inputSchema": {
                  "type": "object",
                  "properties": {
                    "path": { "type": "string", "description": "Directory path" }
                  },
                  "required": ["path"]
                },
                "annotations": {
                  "title": "Delete Directory",
                  "readOnlyHint": false,
                  "destructiveHint": true,
                  "idempotentHint": false,
                  "openWorldHint": false
                }
              }
            ]
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(JSONRPCResponse<MCPClient.ToolsListResponse>.self, from: toolsListJSON)
        let tools = try #require(decoded.result?.tools)
        #expect(tools.count == 2)

        let readTool = tools[0]
        #expect(readTool.annotations?.title == "Read File Contents")
        #expect(readTool.annotations?.isReadOnly == true)
        #expect(readTool.annotations?.isDestructive == false)
        #expect(readTool.annotations?.policyBadgeText == "Read-Only")

        let deleteTool = tools[1]
        #expect(deleteTool.annotations?.title == "Delete Directory")
        #expect(deleteTool.annotations?.isReadOnly == false)
        #expect(deleteTool.annotations?.isDestructive == true)
        #expect(deleteTool.annotations?.policyBadgeText == "Destructive")

        let toolbox = DynamicToolbox()
        let serverId = UUID()
        toolbox.registerMCPTool(readTool, serverId: serverId, serverName: "TestServer")
        toolbox.registerMCPTool(deleteTool, serverId: serverId, serverName: "TestServer")

        #expect(toolbox.toolAnnotations(for: "read_file")?.isReadOnly == true)
        #expect(toolbox.requiresConfirmation(for: "read_file") == false)

        #expect(toolbox.toolAnnotations(for: "delete_directory")?.isDestructive == true)
        #expect(toolbox.requiresConfirmation(for: "delete_directory") == true)
    }

    @Test("W3C traceparent generation, parsing, validation, and rejection of invalid headers")
    func w3cTraceparentFormatAndValidation() {
        let generated = W3CTraceContext.generate(sampled: true)
        #expect(W3CTraceContext.isValidTraceparent(generated.traceparent) == true)
        #expect(generated.isSampled == true)
        #expect(generated.version == "00")
        #expect(generated.traceId.count == 32)
        #expect(generated.spanId.count == 16)
        #expect(generated.traceFlags == "01")

        let parsed = W3CTraceContext.parse(generated.traceparent)
        #expect(parsed == generated)

        let unsampled = W3CTraceContext.generate(sampled: false)
        #expect(unsampled.isSampled == false)
        #expect(unsampled.traceFlags == "00")
        #expect(W3CTraceContext.isValidTraceparent(unsampled.traceparent) == true)

        // Invalid cases per W3C Trace Context spec
        #expect(W3CTraceContext.isValidTraceparent("ff-\(generated.traceId)-\(generated.spanId)-01") == false)
        #expect(W3CTraceContext.isValidTraceparent("00-00000000000000000000000000000000-\(generated.spanId)-01") == false)
        #expect(W3CTraceContext.isValidTraceparent("00-\(generated.traceId)-0000000000000000-01") == false)
        #expect(W3CTraceContext.isValidTraceparent("00-UPPERCASEHEX00000000000000000000-\(generated.spanId)-01") == false)
        #expect(W3CTraceContext.isValidTraceparent("invalid") == false)
    }

    @Test("Real stdio MCP server handshake fallback to 2024-11-05 and W3C traceparent correlation on TraceBus")
    func realStdioFallbackAndTraceBusCorrelation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-modern-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("legacy_mcp_server.py")
        // Python stdio server that rejects 2026-07-28 on initialize, accepts 2024-11-05 on fallback,
        // serves a tool with annotations, and echoes _meta.traceparent on tools/call.
        let pythonScript = """
        import sys, json

        sys.stderr.write("running on stdio\\n")
        sys.stderr.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}

            if req_id is None:
                continue

            if method == "initialize":
                proto = params.get("protocolVersion")
                if proto == "2026-07-28":
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": { "code": -32602, "message": "Unsupported protocolVersion 2026-07-28" }
                    }
                else:
                    resp = {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "protocolVersion": "2024-11-05",
                            "capabilities": { "tools": {} },
                            "serverInfo": { "name": "test-legacy-stdio", "version": "1.0.0" }
                        }
                    }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tools/list":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "tools": [
                            {
                                "name": "echo_trace",
                                "description": "Echoes received W3C traceparent from _meta",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": { "query": { "type": "string" } },
                                    "required": ["query"]
                                },
                                "annotations": {
                                    "title": "Echo Trace",
                                    "readOnlyHint": True,
                                    "destructiveHint": False
                                }
                            }
                        ]
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tools/call":
                meta = params.get("_meta") or {}
                tp = meta.get("traceparent", "missing")
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{ "type": "text", "text": f"traceparent={tp}" }],
                        "isError": False
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
        """
        try pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let orchestrator = await MainActor.run { AgentOrchestrator() }
        let client = MCPClient(
            serverName: "test-legacy-stdio",
            command: "/usr/bin/python3",
            arguments: ["-u", scriptURL.path],
            logger: orchestrator
        )
        defer {
            Task { await client.stop() }
        }

        try await client.start()

        // Verify fallback negotiated version is 2024-11-05
        let negotiated = await client.currentProtocolVersion()
        #expect(negotiated == "2024-11-05")
        let health = await client.health()
        #expect(health.protocolVersion == "2024-11-05")

        // Verify tool annotations from live stdio server
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.annotations?.isReadOnly == true)

        // Verify W3C traceparent propagation in _meta and correlation on TraceBus
        let customTrace = W3CTraceContext.generate(sampled: true)
        let callResult = try await client.callTool(
            name: "echo_trace",
            arguments: ["query": AnyCodable("hello")],
            traceContext: customTrace
        )
        let echoedText = callResult.content.first?.text ?? ""
        #expect(echoedText == "traceparent=\(customTrace.traceparent)")

        // Give TraceBus barrier queue a brief moment to commit the span event
        try await Task.sleep(for: .milliseconds(30))
        let recentTraces = TraceBus.shared.recentEvents(limit: 25)
        let matchingSpan = recentTraces.first {
            $0.operation == "mcp.request" && $0.metadata?["traceparent"] == customTrace.traceparent
        }
        #expect(matchingSpan != nil)
        #expect(matchingSpan?.metadata?["trace_id"] == customTrace.traceId)
        #expect(matchingSpan?.metadata?["span_id"] == customTrace.spanId)
        #expect(matchingSpan?.metadata?["protocol_version"] == "2024-11-05")

        await client.stop()
    }
}
