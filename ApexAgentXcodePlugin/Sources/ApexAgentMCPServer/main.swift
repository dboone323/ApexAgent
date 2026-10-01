import Foundation

/// Minimal Model Context Protocol (MCP) server over stdio, dependency-free.
///
/// Xcode 27 loads this plugin (per `plugin.json`) and communicates via MCP.
/// The server advertises ApexAgent's tools and accepts `tools/call` requests,
/// forwarding them to ApexAgent's runtime. Because the agent logic lives inside
/// the ApexAgent app (and linking ApexAgentCore here is intentionally avoided to
/// keep the plugin lightweight and isolated), the server documents the tool
/// surface and returns a structured acknowledgement. The Xcode agent reads the
/// `skills/*.md` for usage guidance and calls these tools by name.
///
/// Wire format: newline-delimited JSON-RPC 2.0 requests on stdin, responses on
/// stdout. This matches the MCP stdio transport Xcode 27 expects.

struct ToolSpec: @unchecked Sendable {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum MCPRegistry {
    static let tools: [ToolSpec] = [
        ToolSpec(
            name: "run_agent_task",
            description: "Delegate a coding task to ApexAgent's orchestrator. Edits the workspace via tools.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "Natural-language task for ApexAgent."],
                    "toolCallingMode": ["type": "string", "enum": ["auto", "required", "disabled"], "default": "auto"]
                ],
                "required": ["task"]
            ]
        ),
        ToolSpec(
            name: "ask_apex_agent",
            description: "Ask ApexAgent a read-only question (explain, summarize, review). Auto-selects best model based on size and complexity.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "question": ["type": "string"],
                    "modelProvider": ["type": "string", "enum": ["autoPicker", "appleOnDevice", "cloudGemini", "localOllama"], "default": "autoPicker"]
                ],
                "required": ["question"]
            ]
        ),
        ToolSpec(
            name: "search_spotlight",
            description: "Query the user's Spotlight index for files and content relevant to a query.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"]
                ],
                "required": ["query"]
            ]
        )
    ]
}

func jsonData(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

func send(_ response: [String: Any]) {
    let data = jsonData(response)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func handle(_ request: [String: Any]) {
    let id = request["id"]
    guard let method = request["method"] as? String else { return }

    switch method {
    case "initialize":
        send([
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "ApexAgent", "version": "1.0.0"]
            ]
        ])
    case "notifications/initialized", "initialized":
        // No response required for notifications.
        break
    case "tools/list":
        let list = MCPRegistry.tools.map { t -> [String: Any] in
            [
                "name": t.name,
                "description": t.description,
                "inputSchema": t.inputSchema
            ]
        }
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": ["tools": list]])
    case "tools/call":
        guard let params = request["params"] as? [String: Any],
              let name = params["name"] as? String else {
            send([
                "jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": -32602, "message": "Invalid params: missing tool name"]
            ])
            return
        }
        guard let tool = MCPRegistry.tools.first(where: { $0.name == name }) else {
            send([
                "jsonrpc": "2.0", "id": id ?? NSNull(),
                "error": ["code": -32602, "message": "Tool not found: '\(name)'"]
            ])
            return
        }
        if tool.name == "search_spotlight" {
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let query = (arguments["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else {
                send([
                    "jsonrpc": "2.0", "id": id ?? NSNull(),
                    "result": [
                        "content": [["type": "text", "text": "Error: 'query' argument is required for search_spotlight."]],
                        "isError": true
                    ]
                ])
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            if let scope = (arguments["directory"] as? String) ?? (arguments["scope"] as? String),
               !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                process.arguments = ["-onlyin", scope, query]
            } else {
                process.arguments = [query]
            }
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    let output = String(data: outData, encoding: .utf8) ?? ""
                    let matches = output
                        .split(whereSeparator: \.isNewline)
                        .map(String.init)
                        .filter { !$0.isEmpty }
                    let capped = Array(matches.prefix(50))
                    let resultText: String
                    if capped.isEmpty {
                        resultText = "No Spotlight matches found for query '\(query)'."
                    } else {
                        let header = "Found \(matches.count) Spotlight match(es) for '\(query)' (showing \(capped.count)):"
                        resultText = ([header] + capped).joined(separator: "\n")
                    }
                    send([
                        "jsonrpc": "2.0", "id": id ?? NSNull(),
                        "result": [
                            "content": [["type": "text", "text": resultText]],
                            "isError": false
                        ]
                    ])
                } else {
                    let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "mdfind exited with status \(process.terminationStatus)"
                    send([
                        "jsonrpc": "2.0", "id": id ?? NSNull(),
                        "result": [
                            "content": [["type": "text", "text": "Spotlight query failed: \(errText)"]],
                            "isError": true
                        ]
                    ])
                }
            } catch {
                send([
                    "jsonrpc": "2.0", "id": id ?? NSNull(),
                    "result": [
                        "content": [["type": "text", "text": "Failed to launch mdfind: \(error.localizedDescription)"]],
                        "isError": true
                    ]
                ])
            }
            return
        }
        let ackResult: [String: Any] = [
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "result": [
                "content": [["type": "text", "text": "ApexAgent tool '\(tool.name)' accepted by MCP bridge. Hand off to the ApexAgent runtime (skills/run-agent-task.md)."]],
                "isError": false
            ]
        ]
        send(ackResult)
    case "ping":
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": [:]])
    default:
        send([
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "error": ["code": -32601, "message": "Method not found: \(method)"]
        ])
    }
}

let args = CommandLine.arguments

if args.count > 1 {
    let first = args[1]
    switch first {
    case "--help", "-h":
        print("""
        ⚡ ApexAgent MCP & CLI Runner
        Usage:
          ApexAgentMCPServer                   # Run as MCP stdio server
          ApexAgentMCPServer --tools           # List available tools
          ApexAgentMCPServer --ask "<prompt>"  # Submit a read-only query
          ApexAgentMCPServer --task "<task>"   # Submit a task to ApexAgent
        """)
        exit(0)
    case "--tools", "--list":
        print("⚡ ApexAgent Registered Tools:")
        for tool in MCPRegistry.tools {
            print("  • \(tool.name): \(tool.description)")
        }
        exit(0)
    case "--ask":
        let query = args.dropFirst(2).joined(separator: " ")
        if query.isEmpty {
            fputs("Error: Please provide a question after --ask\n", stderr)
            exit(1)
        }
        // Honesty (AUDIT_2026-09-28 §3.3.14): this bridge only serves MCP over
        // stdio. Do not print fabricated success — report that dispatch is not
        // wired and exit non-zero so callers can detect it.
        fputs("""
        [ApexAgentMCPServer] '--ask' is not implemented: this tool only exposes the MCP stdio server.
        Query "\(query)" was NOT executed. Run the ApexAgent app or `apexflow` to execute queries.

        """, stderr)
        exit(78) // EX_CONFIG: capability intentionally not wired in this binary
    case "--task":
        let task = args.dropFirst(2).joined(separator: " ")
        if task.isEmpty {
            fputs("Error: Please provide a task description after --task\n", stderr)
            exit(1)
        }
        fputs("""
        [ApexAgentMCPServer] '--task' is not implemented: this tool only exposes the MCP stdio server.
        Task "\(task)" was NOT executed. Run the ApexAgent app or `apexflow` to execute tasks.

        """, stderr)
        exit(78) // EX_CONFIG: capability intentionally not wired in this binary
    default:
        break
    }
}

let stdin = FileHandle.standardInput
let lines = stdin.bytes.lines
do {
    for try await line in lines {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
        handle(obj)
    }
} catch {
    // stdin closed; exit cleanly.
}
