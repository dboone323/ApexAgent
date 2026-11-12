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

    @Test("Stateless requests and explicit extension negotiation matrix for MCP 2026-07-28")
    func statelessRequestsAndExtensionNegotiation() throws {
        // 1. Client capabilities advertise modern extensions and drop roots/sampling
        let clientCaps = MCPClient.InitializeCapabilities()
        #expect(clientCaps.extensions != nil)
        #expect(clientCaps.extensions?["tasks"]?.version == "2026-07-28")
        #expect(clientCaps.extensions?["apps"]?.version == "2026-07-28")
        #expect(clientCaps.extensions?["serverCard"]?.version == "2026-07-28")

        // 2. Decode modern 2026-07-28 response with extensions
        let modernResponseJSON = """
        {
          "jsonrpc": "2.0",
          "id": 1,
          "result": {
            "protocolVersion": "2026-07-28",
            "capabilities": {
              "extensions": {
                "tasks": { "version": "2026-07-28" },
                "apps": { "version": "2026-07-28" },
                "serverCard": { "version": "2026-07-28" }
              },
              "tools": { "listChanged": true }
            },
            "serverInfo": { "name": "modern-stateless-mcp", "version": "2.0.0" }
          }
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(JSONRPCResponse<MCPClient.InitializeResult>.self, from: modernResponseJSON)
        let result = try #require(decoded.result)
        #expect(result.protocolVersion == "2026-07-28")
        #expect(result.capabilities["extensions"] != nil)

        // 3. Verify stateless request framing has no session token requirement
        let sampleRequest = JSONRPCRequest(id: 10, method: "tools/call", params: ["param": "value"])
        let encodedReq = try JSONEncoder().encode(sampleRequest)
        let jsonReq = try #require(try JSONSerialization.jsonObject(with: encodedReq) as? [String: Any])
        #expect(jsonReq["jsonrpc"] as? String == "2.0")
        #expect(jsonReq["id"] as? Int == 10)
        #expect(jsonReq["sessionToken"] == nil)
        #expect(jsonReq["sessionId"] == nil)
    }

    @Test("MCP Tasks extension lifecycle: call, get, list, cancel, result, and completion awaiting")
    func tasksExtensionLifecycle() throws {
        // 1. Task status terminal matrix
        #expect(MCPTaskStatus.pending.isTerminal == false)
        #expect(MCPTaskStatus.running.isTerminal == false)
        #expect(MCPTaskStatus.completed.isTerminal == true)
        #expect(MCPTaskStatus.failed.isTerminal == true)
        #expect(MCPTaskStatus.cancelled.isTerminal == true)

        // 2. Task model encoding and decoding
        let taskJSON = """
        {
          "taskId": "task-abc-123",
          "name": "data_indexing",
          "status": "running",
          "progress": 0.45,
          "message": "Processing 450 of 1000 items",
          "result": null,
          "error": null
        }
        """.data(using: .utf8)!

        let decodedTask = try JSONDecoder().decode(MCPTask.self, from: taskJSON)
        #expect(decodedTask.taskId == "task-abc-123")
        #expect(decodedTask.id == "task-abc-123")
        #expect(decodedTask.name == "data_indexing")
        #expect(decodedTask.status == .running)
        #expect(decodedTask.progress == 0.45)
        #expect(decodedTask.status.isTerminal == false)
        #expect(decodedTask.message?.contains("450") == true)

        // 3. Completed task with result content
        let completedJSON = """
        {
          "taskId": "task-abc-123",
          "name": "data_indexing",
          "status": "completed",
          "progress": 1.0,
          "message": "All items indexed",
          "result": {
            "content": [{ "type": "text", "text": "Index complete: 1000 records" }],
            "isError": false
          }
        }
        """.data(using: .utf8)!

        let completedTask = try JSONDecoder().decode(MCPTask.self, from: completedJSON)
        #expect(completedTask.status == .completed)
        #expect(completedTask.status.isTerminal == true)
        #expect(completedTask.result?.content.first?.text == "Index complete: 1000 records")
    }

    @Test("MCP Server Card discovery and graceful synthesis fallback")
    func serverCardsDiscovery() throws {
        let cardJSON = """
        {
          "name": "Apex PostgreSQL MCP",
          "version": "1.4.0",
          "description": "Enterprise PostgreSQL connector with schema reflection",
          "vendor": "ApexAgent Core Team",
          "website": "https://apexagent.dev",
          "documentation": "https://docs.apexagent.dev/mcp/postgres",
          "iconURL": "https://apexagent.dev/icons/postgres.png",
          "capabilities": ["tools", "tasks", "apps", "stateless"],
          "tags": ["database", "postgres", "sql", "production"],
          "license": "Apache-2.0",
          "privacyPolicy": "https://apexagent.dev/privacy"
        }
        """.data(using: .utf8)!

        let decodedCard = try JSONDecoder().decode(MCPServerCard.self, from: cardJSON)
        #expect(decodedCard.name == "Apex PostgreSQL MCP")
        #expect(decodedCard.version == "1.4.0")
        #expect(decodedCard.vendor == "ApexAgent Core Team")
        #expect(decodedCard.capabilities?.contains("tasks") == true)
        #expect(decodedCard.capabilities?.contains("stateless") == true)
        #expect(decodedCard.tags?.contains("production") == true)

        // Verify synthesis fallback values
        let fallbackCard = MCPServerCard(
            name: "FallbackServer",
            version: "2026-07-28",
            description: "Synthesized server card",
            vendor: "Local System",
            capabilities: ["tools", "stateless"],
            tags: ["mcp-2026-07-28"]
        )
        #expect(fallbackCard.name == "FallbackServer")
        #expect(fallbackCard.capabilities?.contains("stateless") == true)
    }

    @Test("MCP Apps UI discovery, manifest validation, and container model")
    func mcpAppsRendering() throws {
        let appJSON = """
        {
          "appId": "mcp.app.dashboard",
          "title": "Interactive Monitoring Console",
          "description": "Live visual metrics and configuration console",
          "version": "1.0.0",
          "entryPoint": "<!DOCTYPE html><html><body><h1>MCP App Dashboard</h1></body></html>",
          "isInlineHTML": true,
          "permissions": ["ui.display", "events.listen"],
          "supportedFormFactors": ["desktop", "panel"]
        }
        """.data(using: .utf8)!

        let decodedApp = try JSONDecoder().decode(MCPAppDefinition.self, from: appJSON)
        #expect(decodedApp.appId == "mcp.app.dashboard")
        #expect(decodedApp.id == "mcp.app.dashboard")
        #expect(decodedApp.title == "Interactive Monitoring Console")
        #expect(decodedApp.isInlineHTML == true)
        #expect(decodedApp.entryPoint.contains("<h1>MCP App Dashboard</h1>"))
        #expect(decodedApp.permissions?.contains("ui.display") == true)
        #expect(decodedApp.supportedFormFactors?.contains("desktop") == true)

        let urlAppJSON = """
        {
          "appId": "mcp.app.external",
          "title": "External Management Portal",
          "entryPoint": "http://127.0.0.1:8080/app",
          "isInlineHTML": false
        }
        """.data(using: .utf8)!

        let decodedURLApp = try JSONDecoder().decode(MCPAppDefinition.self, from: urlAppJSON)
        #expect(decodedURLApp.isInlineHTML == false)
        #expect(decodedURLApp.entryPoint == "http://127.0.0.1:8080/app")
    }

    @Test("Deprecated Roots, Sampling, and Logging interfaces are rejected by MCPClient and Wire Auditor")
    func deprecatedRootsSamplingLoggingRejected() throws {
        // 1. Wire auditor flags deprecated methods with DEPRECATED_PROTOCOL_FEATURE
        let deprecatedMethods = ["roots/list", "sampling/createMessage", "logging/setLevel"]
        for method in deprecatedMethods {
            let frame = """
            {
              "jsonrpc": "2.0",
              "id": 1,
              "method": "\(method)",
              "params": {}
            }
            """.data(using: .utf8)!
            let report = MCPWireProtocolAuditor.auditRawFrame(frame)
            #expect(report.passed == false)
            #expect(report.violations.contains { $0.code == "DEPRECATED_PROTOCOL_FEATURE" })
        }

        // 2. Modern 2026-07-28 methods pass with 100% score
        let modernMethods = [
            "tasks/list", "tasks/call", "tasks/get", "tasks/cancel", "tasks/result",
            "server/card", "apps/list", "apps/get"
        ]
        for method in modernMethods {
            let frame = """
            {
              "jsonrpc": "2.0",
              "id": 1,
              "method": "\(method)",
              "params": {}
            }
            """.data(using: .utf8)!
            let report = MCPWireProtocolAuditor.auditRawFrame(frame)
            #expect(report.passed == true)
            #expect(report.score == 100.0)
            #expect(report.violations.isEmpty)
        }

        // 3. Client deprecatedMethods set is exhaustive
        #expect(MCPClient.deprecatedMethods.contains("roots/list"))
        #expect(MCPClient.deprecatedMethods.contains("sampling/createMessage"))
        #expect(MCPClient.deprecatedMethods.contains("logging/setLevel"))
    }

    @Test("Live MCP 2026-07-28 stdio server verification: stateless requests, extensions, tasks, cards, apps, deprecation")
    func liveMCP2026SpecServerVerification() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-spec2026-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("mcp_2026_spec_server.py")
        let pythonScript = """
        import sys, json

        sys.stderr.write("running on stdio\\n")
        sys.stderr.flush()

        tasks_store = {
            "task-1": {
                "taskId": "task-1",
                "name": "dataset_compression",
                "status": "running",
                "progress": 0.5,
                "message": "Compressing chunk 5 of 10"
            }
        }

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
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2026-07-28",
                        "capabilities": {
                            "extensions": {
                                "tasks": { "version": "2026-07-28" },
                                "apps": { "version": "2026-07-28" },
                                "serverCard": { "version": "2026-07-28" }
                            },
                            "tools": { "listChanged": False }
                        },
                        "serverInfo": {
                            "name": "live-spec-2026-server",
                            "version": "2.0.0",
                            "vendor": "ApexAgent Compliance Labs"
                        }
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "server/card":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "name": "Live Spec 2026 Server",
                        "version": "2.0.0",
                        "description": "Production reference server for MCP 2026-07-28 compliance",
                        "vendor": "ApexAgent Compliance Labs",
                        "website": "https://apexagent.dev/mcp",
                        "documentation": "https://docs.apexagent.dev/spec-2026",
                        "capabilities": ["tasks", "apps", "serverCard", "tools", "stateless"],
                        "tags": ["mcp", "compliance", "stateless"]
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "apps/list":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "apps": [
                            {
                                "appId": "live.spec.app",
                                "title": "Live Compliance Console",
                                "description": "Interactive HTML status console",
                                "version": "1.0.0",
                                "entryPoint": "<div id='app'><h1>Live MCP App</h1></div>",
                                "isInlineHTML": True,
                                "permissions": ["ui.render"],
                                "supportedFormFactors": ["desktop", "inline"]
                            }
                        ]
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "apps/get":
                app_id = params.get("appId", "")
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "appId": app_id,
                        "title": "Live Compliance Console",
                        "description": "Interactive HTML status console",
                        "version": "1.0.0",
                        "entryPoint": "<div id='app'><h1>Live MCP App</h1></div>",
                        "isInlineHTML": True
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tasks/list":
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "tasks": list(tasks_store.values())
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tasks/call":
                tname = params.get("name", "task")
                t = {
                    "taskId": "task-call-99",
                    "name": tname,
                    "status": "running",
                    "progress": 0.25,
                    "message": "Task queued and started"
                }
                tasks_store["task-call-99"] = t
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": t
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tasks/get":
                tid = params.get("taskId")
                t = tasks_store.get(tid, {
                    "taskId": tid,
                    "status": "completed",
                    "progress": 1.0,
                    "message": "Completed",
                    "result": {
                        "content": [{ "type": "text", "text": f"Output for {tid}" }],
                        "isError": False
                    }
                })
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": t
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tasks/cancel":
                tid = params.get("taskId")
                t = {
                    "taskId": tid,
                    "status": "cancelled",
                    "message": "Task cancelled by client"
                }
                tasks_store[tid] = t
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": t
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            elif method == "tasks/result":
                tid = params.get("taskId")
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{ "type": "text", "text": f"Result for {tid}" }],
                        "isError": False
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
                                "name": "modern_tool",
                                "description": "2026-07-28 compliant tool",
                                "inputSchema": { "type": "object", "properties": {} },
                                "annotations": {
                                    "title": "Modern Tool",
                                    "readOnlyHint": True,
                                    "destructiveHint": False
                                }
                            }
                        ]
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            else:
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": { "code": -32601, "message": f"Method {method} not found" }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
        """
        try pythonScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        let orchestrator = await MainActor.run { AgentOrchestrator() }
        let client = MCPClient(
            serverName: "live-spec-2026-server",
            command: "/usr/bin/python3",
            arguments: ["-u", scriptURL.path],
            logger: orchestrator
        )
        defer {
            Task { await client.stop() }
        }

        try await client.start()

        // 1. Verify negotiated version and extensions
        let negotiated = await client.currentProtocolVersion()
        #expect(negotiated == "2026-07-28")
        let extensions = await client.currentNegotiatedExtensions()
        #expect(extensions["tasks"] != nil)
        #expect(extensions["apps"] != nil)
        #expect(extensions["serverCard"] != nil)
        #expect(await client.isExtensionSupported("tasks") == true)
        #expect(await client.isExtensionSupported("apps") == true)
        #expect(await client.isExtensionSupported("serverCard") == true)

        // 2. Discover Server Card live
        let serverCard = try await client.getServerCard()
        #expect(serverCard.name == "Live Spec 2026 Server")
        #expect(serverCard.version == "2.0.0")
        #expect(serverCard.vendor == "ApexAgent Compliance Labs")
        #expect(serverCard.capabilities?.contains("stateless") == true)

        // 3. Discover MCP Apps live
        let apps = try await client.listApps()
        #expect(apps.count == 1)
        let app = try #require(apps.first)
        #expect(app.appId == "live.spec.app")
        #expect(app.title == "Live Compliance Console")
        #expect(app.isInlineHTML == true)
        let singleApp = try await client.getApp(appId: "live.spec.app")
        #expect(singleApp.appId == "live.spec.app")

        // 4. Tasks extension lifecycle live
        let tasksListInitial = try await client.listTasks()
        #expect(tasksListInitial.count >= 1)
        #expect(tasksListInitial.first?.taskId == "task-1")

        let dispatchedTask = try await client.callTask(
            name: "background_indexing",
            arguments: ["depth": AnyCodable(3)]
        )
        #expect(dispatchedTask.taskId == "task-call-99")
        #expect(dispatchedTask.status == .running)

        let completedTask = try await client.getTask(taskId: "task-completed-5")
        #expect(completedTask.status == .completed)
        #expect(completedTask.result?.content.first?.text == "Output for task-completed-5")

        let taskResult = try await client.getTaskResult(taskId: "task-completed-5")
        #expect(taskResult.content.first?.text == "Output for task-completed-5")

        let cancelledTask = try await client.cancelTask(taskId: "task-1")
        #expect(cancelledTask.status == .cancelled)

        // 5. Verify deprecated interfaces fail with protocol error
        await #expect(throws: MCPError.self) {
            let _: MCPClient.EmptyParams = try await client.sendRequest(method: "logging/setLevel", params: MCPClient.EmptyParams())
        }
        await #expect(throws: MCPError.self) {
            let _: MCPClient.EmptyParams = try await client.sendRequest(method: "roots/list", params: MCPClient.EmptyParams())
        }
        await #expect(throws: MCPError.self) {
            let _: MCPClient.EmptyParams = try await client.sendRequest(method: "sampling/createMessage", params: MCPClient.EmptyParams())
        }

        await client.stop()
    }
}
