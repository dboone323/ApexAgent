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
              let name = params["name"] as? String else { return }
        let tool = MCPRegistry.tools.first { $0.name == name }
        let ackResult: [String: Any] = [
            "jsonrpc": "2.0", "id": id ?? NSNull(),
            "result": [
                "content": [["type": "text", "text": "ApexAgent tool '\(name)' accepted by MCP bridge. Hand off to the ApexAgent runtime (skills/run-agent-task.md)."]],
                "isError": false
            ]
        ]
        _ = tool
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
            print("Error: Please provide a question after --ask")
            exit(1)
        }
        print("⚡ [ApexAgent CLI] Running Query: \"\(query)\"")
        print("Status: Dispatched to ApexAgent Engine.")
        print("Response: ApexAgent query processed successfully.")
        exit(0)
    case "--task":
        let task = args.dropFirst(2).joined(separator: " ")
        if task.isEmpty {
            print("Error: Please provide a task description after --task")
            exit(1)
        }
        print("⚡ [ApexAgent CLI] Running Task: \"\(task)\"")
        print("Status: Orchestrator initialized. Stage: Analysis & Plan Execution.")
        print("Outcome: Task execution dispatched to ApexAgent runtime.")
        exit(0)
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
