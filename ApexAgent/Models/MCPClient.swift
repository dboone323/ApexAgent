import Foundation
import Observation

struct MCPToolDefinition: Codable {
    let name: String
    let description: String?
    let inputSchema: MCPInputSchema
}

struct MCPInputSchema: Codable {
    let type: String
    let properties: [String: MCPProperty]?
    let required: [String]?
}

struct MCPProperty: Codable {
    let type: String
    let description: String?
}

struct MCPToolCallResult: Codable {
    let content: [MCPContentBlock]
    let isError: Bool?
}

struct MCPContentBlock: Codable {
    let type: String
    let text: String?
}

// JSON-RPC structs
struct JSONRPCRequest<T: Codable>: Codable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: T

    enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params
    }
}

struct JSONRPCResponse<T: Codable>: Codable {
    let jsonrpc: String
    let id: Int?
    let result: T?
    let error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: String?
}

actor MCPClient {
    nonisolated let serverName: String
    let command: String
    let arguments: [String]

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]

    init(serverName: String, command: String, arguments: [String] = []) {
        self.serverName = serverName
        self.command = command
        self.arguments = arguments
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        guard process == nil else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")

        // Wrap command in zsh shell execution to support environment loading and paths
        let shellArgs = ["-c", "\(command) " + arguments.joined(separator: " ")]
        proc.arguments = shellArgs

        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath

        if AgentOrchestrator.isFolderAccessRestricted() {
            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser
            let sandboxDir = homeDir.appendingPathComponent(".apex/sandbox")
            try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
            env["HOME"] = sandboxDir.path
        }

        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        try proc.run()

        // Listen to stdout stream in background
        let outPipe = self.stdoutPipe
        let serverNameForStdout = self.serverName
        Task.detached { [weak self] in
            guard let self = self, let pipe = outPipe else { return }
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            while true {
                do {
                    guard let data = try handle.read(upToCount: 4096), !data.isEmpty else {
                        break
                    }
                    buffer.append(data)

                    // Process lines separated by newlines (standard stdio JSON-RPC pattern)
                    while let newlineIndex = buffer.firstIndex(of: 10) { // 10 is '\n'
                        let lineData = buffer.subdata(in: 0..<newlineIndex)
                        buffer.removeSubrange(0...newlineIndex)

                        if !lineData.isEmpty {
                            await self.handleIncomingMessage(lineData)
                        }
                    }
                } catch {
                    await AgentOrchestrator.shared?.logToolEnd(
                        name: "mcp:\(serverNameForStdout)",
                        result: "MCPClient stdout read error: \(error)",
                        status: .failed("MCPClient stdout read error")
                    )
                    break
                }
            }
        }

        // Listen to stderr stream in background
        let errPipe = self.stderrPipe
        let serverNameForLogs = self.serverName
        Task.detached { [weak self] in
            guard let self = self, let pipe = errPipe else { return }
            let handle = pipe.fileHandleForReading
            while true {
                do {
                    guard let data = try handle.read(upToCount: 4096), !data.isEmpty else {
                        break
                    }
                    let chunk = String(data: data, encoding: .utf8) ?? ""
                    if !chunk.isEmpty {
                        await AgentOrchestrator.shared?.logToolEnd(
                            name: "mcp:\(serverNameForLogs)",
                            result: "stderr: \(chunk)",
                            status: .failed("MCP stderr output")
                        )
                    }
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: NSError(domain: "MCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client stopped."]))
        }
        pendingRequests.removeAll()
    }

    func isRunning() -> Bool {
        return process?.isRunning ?? false
    }

    private func handleIncomingMessage(_ data: Data) {
        // Parse incoming message. In JSON-RPC 2.0, standard responses have an `id` matching our request
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return
        }

        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }

    func sendRequest<Params: Codable, Result: Codable>(method: String, params: Params) async throws -> Result {
        if !isRunning() {
            try start()
        }

        let id = nextRequestId
        nextRequestId += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        guard let stdin = stdinPipe else {
            throw NSError(domain: "MCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Stdin pipe not available."])
        }

        // Write the request data followed by newline
        var fullData = requestData
        fullData.append(10) // '\n'

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            do {
                try stdin.fileHandleForWriting.write(contentsOf: fullData)
            } catch {
                pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(JSONRPCResponse<Result>.self, from: responseData)
        if let error = response.error {
            throw NSError(domain: "MCPClient", code: error.code, userInfo: [NSLocalizedDescriptionKey: error.message])
        }
        guard let result = response.result else {
            throw NSError(domain: "MCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Empty result from MCP server."])
        }
        return result
    }

    // MARK: - MCP API Protocol Methods

    struct EmptyParams: Codable {}

    struct ToolsListResponse: Codable {
        let tools: [MCPToolDefinition]
    }

    func listTools() async throws -> [MCPToolDefinition] {
        let response: ToolsListResponse = try await sendRequest(method: "tools/list", params: EmptyParams())
        return response.tools
    }

    struct CallToolParams: Codable {
        let name: String
        let arguments: [String: AnyCodable]
    }

    func callTool(name: String, arguments: [String: AnyCodable]) async throws -> MCPToolCallResult {
        let params = CallToolParams(name: name, arguments: arguments)
        let result: MCPToolCallResult = try await sendRequest(method: "tools/call", params: params)
        return result
    }
}

// AnyCodable helper to serialize dictionary payloads containing String/Int/Double/Bool/Array/Dictionary
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }
}
