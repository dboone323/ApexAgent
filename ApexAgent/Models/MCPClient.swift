import Foundation
import Observation

enum MCPError: Error, LocalizedError {
    case connectionFailed(String)
    case timeout(String)
    case protocolError(String)
    case circuitOpen
    
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "MCP Connection Failed: \(msg)"
        case .timeout(let msg): return "MCP Timeout: \(msg)"
        case .protocolError(let msg): return "MCP Protocol Error: \(msg)"
        case .circuitOpen: return "MCP Circuit Breaker Open (too many failures)"
        }
    }
}

struct MCPClientConfig: Codable, Sendable, Equatable {
    var requestTimeout: TimeInterval
    var pingTimeout: TimeInterval
    var maxRetries: Int
    var circuitFailureThreshold: Int
    var restartRateLimitWindow: TimeInterval
    var maxRestartsInWindow: Int

    static let `default` = MCPClientConfig(
        requestTimeout: 60,
        pingTimeout: 3,
        maxRetries: 5,
        circuitFailureThreshold: 3,
        restartRateLimitWindow: 60,
        maxRestartsInWindow: 3
    )
}

struct MCPClientHealth: Codable, Sendable, Equatable {
    let serverName: String
    let isRunning: Bool
    let circuitOpen: Bool
    let failureCount: Int
    let restartCountInWindow: Int

    init(
        serverName: String,
        isRunning: Bool = false,
        circuitOpen: Bool = false,
        failureCount: Int = 0,
        restartCountInWindow: Int = 0
    ) {
        self.serverName = serverName
        self.isRunning = isRunning
        self.circuitOpen = circuitOpen
        self.failureCount = failureCount
        self.restartCountInWindow = restartCountInWindow
    }
}

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
    let type: String?
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
    let jsonrpc: String
    let id: Int
    let method: String
    let params: T

    init(id: Int, method: String, params: T) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }

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

struct JSONRPCNotification: Codable {
    let jsonrpc: String
    let method: String

    init(method: String) {
        self.jsonrpc = "2.0"
        self.method = method
    }
}

actor MCPClient {
    nonisolated let serverName: String
    let command: String
    let arguments: [String]
    private let logger: ToolEventLogger
    let orchestrator: OrchestratorProvider?
    let config: MCPClientConfig
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    
    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]
    
    // Hardening configurations
    private let maxRetries = 5
    private var failureCount = 0
    private var circuitOpen = false
    private var lastRestartTime = Date.distantPast
    private var restartCountInWindow = 0
    
    /// Public read-only circuit state for observability and tests.
    public func isCircuitOpen() async -> Bool {
        return circuitOpen
    }
    
    /// Reset circuit/failure state so a server can be retried cleanly.
    func resetCircuit() {
        circuitOpen = false
        failureCount = 0
    }

    /// Test/control path: simulate a permanently failed circuit without
    /// depending on a real server or a fixed number of request failures.
    func openCircuit() {
        circuitOpen = true
        failureCount = maxRetries
    }
    
    init(serverName: String, command: String, arguments: [String] = [], logger: ToolEventLogger, orchestrator: OrchestratorProvider? = nil, config: MCPClientConfig = .default) {
        self.serverName = serverName
        self.command = command
        self.arguments = arguments
        self.logger = logger
        self.orchestrator = orchestrator
        self.config = config
    }
    
    func start() async throws {
        signal(SIGPIPE, SIG_IGN)
        guard process == nil else { return }
        
        let isRestricted = await MainActor.run { orchestrator?.orchestrator.isFolderAccessRestricted() ?? false }
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        
        // Wrap command in zsh shell execution to support environment loading and paths
        // Use exec to replace the shell process image with the child process, so signals propagate correctly.
        let shellArgs = ["-c", "exec \(command) " + arguments.joined(separator: " ")]
        proc.arguments = shellArgs
        
        var env = ProcessInfo.processInfo.environment
        // Build PATH from the current process environment plus standard Homebrew /
        // local install locations. Do NOT hardcode any developer home directory.
        // Prepend the user's ~/.local/bin (resolved at runtime) and the common
        // brew/system locations so tools like python3 / npx resolve on any Mac.
        let currentPath = env["PATH"] ?? ""
        let userLocalBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin").path
        let standardPaths = [userLocalBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let existing = currentPath.split(separator: ":").map(String.init)
        // De-duplicate while preserving order: standard prefixes first, then inherited PATH.
        var seen = Set<String>()
        var merged: [String] = []
        for p in standardPaths + existing where !p.isEmpty && seen.insert(p).inserted {
            merged.append(p)
        }
        env["PATH"] = merged.joined(separator: ":")
        
        if isRestricted {
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
        
        // Supervision - monitor exit code
        proc.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            Task {
                await self.handleTermination(status: process.terminationStatus)
            }
        }

        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        try proc.run()

        // Listen to stdout stream in background using DispatchSourceRead
        let stdoutFd = stdout.fileHandleForReading.fileDescriptor
        _ = fcntl(stdoutFd, F_SETFL, O_NONBLOCK)
        let stdoutSrc = DispatchSource.makeReadSource(fileDescriptor: stdoutFd, queue: DispatchQueue.global())
        
        var stdoutBuffer = Data()
        stdoutSrc.setEventHandler { [weak self, weak stdoutSrc] in
            guard let self = self, let stdoutSrc = stdoutSrc else { return }
            let available = stdoutSrc.data
            guard available > 0 else {
                stdoutSrc.cancel()
                return
            }
            
            do {
                if let data = try? stdout.fileHandleForReading.read(upToCount: Int(available)), !data.isEmpty {
                    stdoutBuffer.append(data)
                    while let newlineIndex = stdoutBuffer.firstIndex(of: 10) {
                        let lineData = stdoutBuffer.subdata(in: 0..<newlineIndex)
                        stdoutBuffer.removeSubrange(0...newlineIndex)
                        if !lineData.isEmpty {
                            Task {
                                await self.handleIncomingMessage(lineData)
                            }
                        }
                    }
                } else {
                    stdoutSrc.cancel()
                }
            }
        }
        stdoutSrc.resume()
        self.stdoutSource = stdoutSrc

        // Listen to stderr stream in background using DispatchSourceRead
        let stderrFd = stderr.fileHandleForReading.fileDescriptor
        _ = fcntl(stderrFd, F_SETFL, O_NONBLOCK)
        let stderrSrc = DispatchSource.makeReadSource(fileDescriptor: stderrFd, queue: DispatchQueue.global())
        let serverNameForLogs = self.serverName
        
        stderrSrc.setEventHandler { [weak stderrSrc] in
            guard let stderrSrc = stderrSrc else { return }
            let available = stderrSrc.data
            guard available > 0 else {
                stderrSrc.cancel()
                return
            }
            if let data = try? stderr.fileHandleForReading.read(upToCount: Int(available)), !data.isEmpty {
                if let logStr = String(data: data, encoding: .utf8) {
                    print("📡 [MCP Server - \(serverNameForLogs) Stderr]: \(logStr)")
                }
            } else {
                stderrSrc.cancel()
            }
        }
        stderrSrc.resume()
        self.stderrSource = stderrSrc
        
        try await performInitializeHandshake()
    }
    
    private struct InitializeParams: Codable {
        struct ClientInfo: Codable {
            let name: String
            let version: String
        }
        struct Capabilities: Codable {
            var sampling: [String: AnyCodable]? = nil
            var roots: [String: AnyCodable]? = nil
        }
        let protocolVersion: String
        let capabilities: Capabilities
        let clientInfo: ClientInfo
    }
    
    private struct InitializeResult: Codable {
        let protocolVersion: String
        let capabilities: [String: AnyCodable]
        let serverInfo: [String: AnyCodable]
    }
    
    private func performInitializeHandshake() async throws {
        let params = InitializeParams(
            protocolVersion: "2024-11-05",
            capabilities: InitializeParams.Capabilities(),
            clientInfo: InitializeParams.ClientInfo(name: "ApexAgent", version: "1.0.0")
        )
        
        let _: InitializeResult = try await sendRequestInternal(method: "initialize", params: params)
        
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let encoder = JSONEncoder()
        let notifData = try encoder.encode(notification)
        
        guard let stdin = stdinPipe else {
            throw MCPError.connectionFailed("Stdin pipe not available for initialized notification.")
        }
        
        var fullData = notifData
        fullData.append(10) // '\n'
        
        try stdin.fileHandleForWriting.write(contentsOf: fullData)
    }
    
    private func startWithRetry() async throws {
        var lastError: Error?
        let delayBase = 0.5
        for attempt in 0..<maxRetries {
            do {
                try await start()
                let healthy = await ping()
                if healthy {
                    failureCount = 0
                    circuitOpen = false
                    return
                } else {
                    throw MCPError.connectionFailed("Ping health check failed.")
                }
            } catch {
                lastError = error
                stop()
                if attempt < maxRetries - 1 {
                    let delay = delayBase * pow(2.0, Double(attempt))
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
        circuitOpen = true
        throw lastError ?? MCPError.connectionFailed("Failed to connect after \(maxRetries) attempts.")
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrSource?.cancel()
        stderrSource = nil
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: NSError(domain: "MCPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Client stopped."]))
        }
        pendingRequests.removeAll()
    }

    func isRunning() -> Bool {
        return process?.isRunning ?? false
    }

    func health() -> MCPClientHealth {
        MCPClientHealth(
            serverName: serverName,
            isRunning: isRunning(),
            circuitOpen: circuitOpen,
            failureCount: failureCount,
            restartCountInWindow: restartCountInWindow
        )
    }

    nonisolated var maxRetryCount: Int { maxRetries }

    private func handleIncomingMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return
        }

        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }
    
    private func handleTermination(status: Int32) async {
        guard status != 0 else { return } // normal exit
        
        let now = Date()
        if now.timeIntervalSince(lastRestartTime) > 60 {
            lastRestartTime = now
            restartCountInWindow = 1
        } else {
            restartCountInWindow += 1
        }
        
        if restartCountInWindow <= 3 {
            await logger.logToolEnd(
                name: "mcp:\(serverName)",
                result: "MCP Server crashed (status \(status)). Attempting automatic restart...",
                status: .failed("MCP Server crashed")
            )
            stop()
            try? await startWithRetry()
        } else {
            await logger.logToolEnd(
                name: "mcp:\(serverName)",
                result: "MCP Server crashed (status \(status)) repeatedly. Supervision rate limit reached. Circuit opened.",
                status: .failed("MCP Server repeatedly crashed")
            )
            circuitOpen = true
            stop()
        }
    }
    
    private func registerAndWrite(id: Int, data: Data, stdin: Pipe) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingRequests[id] = continuation
            do {
                try stdin.fileHandleForWriting.write(contentsOf: data)
            } catch {
                self.pendingRequests.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Resume a pending request continuation with a timeout error if it is
    /// still outstanding. Called from the request watchdog so an unresponsive
    /// MCP server cannot hang the caller forever. Safe against double-resume:
    /// `removeValue` atomically claims the continuation.
    private func resumeOnTimeout(id: Int) {
        if let continuation = pendingRequests.removeValue(forKey: id) {
            continuation.resume(throwing: MCPError.timeout("Request timed out after 60 seconds."))
        }
    }
    
    func ping() async -> Bool {
        do {
            let id = self.nextRequestId
            self.nextRequestId += 1
            let request = JSONRPCRequest(id: id, method: "tools/list", params: EmptyParams())
            let encoder = JSONEncoder()
            let requestData = try encoder.encode(request)
            guard let stdin = self.stdinPipe else { return false }
            var fullData = requestData
            fullData.append(10)
            
            let dataToShare = fullData
            let stdinToShare = stdin
            let responseData = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [id, dataToShare, stdinToShare] in
                    try await self.registerAndWrite(id: id, data: dataToShare, stdin: stdinToShare)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(3))
                    throw MCPError.timeout("Ping timeout")
                }
                guard let result = try await group.next() else {
                    throw MCPError.timeout("Ping timeout")
                }
                group.cancelAll()
                return result
            }
            let decoder = JSONDecoder()
            let response = try decoder.decode(JSONRPCResponse<ToolsListResponse>.self, from: responseData)
            return response.result != nil
        } catch {
            return false
        }
    }

    func sendRequest<Params: Codable, Result: Codable>(method: String, params: Params) async throws -> Result {
        if circuitOpen {
            throw MCPError.circuitOpen
        }
        
        if !isRunning() {
            try await startWithRetry()
        }

        return try await sendRequestInternal(method: method, params: params)
    }

    private func sendRequestInternal<Params: Codable, Result: Codable>(method: String, params: Params) async throws -> Result {
        let id = nextRequestId
        nextRequestId += 1

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        guard let stdin = stdinPipe else {
            throw MCPError.connectionFailed("Stdin pipe not available.")
        }

        var fullData = requestData
        fullData.append(10) // '\n'
        let dataToShare = fullData
        let stdinToShare = stdin
        let responseData: Data = try await Tracing.span("mcp.request", source: "MCPClient", metadata: ["method": method]) {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { [id, dataToShare, stdinToShare] in
                    try await self.registerAndWrite(id: id, data: dataToShare, stdin: stdinToShare)
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(60))
                    // Force-resume the suspended continuation so an unresponsive
                    // server cannot hang the caller forever. removeValue is atomic,
                    // so the real response path and this timeout path cannot both
                    // resume the same continuation (which would crash).
                    await self.resumeOnTimeout(id: id)
                    throw MCPError.timeout("Request timed out after 60 seconds.")
                }

                guard let resultData = try await group.next() else {
                    throw MCPError.timeout("Request timed out")
                }
                group.cancelAll()
                return resultData
            }
        }

        let decoder = JSONDecoder()
        let response = try decoder.decode(JSONRPCResponse<Result>.self, from: responseData)
        if let error = response.error {
            failureCount += 1
            if failureCount >= 3 {
                circuitOpen = true
            }
            throw MCPError.protocolError(error.message)
        }
        guard let result = response.result else {
            failureCount += 1
            if failureCount >= 3 {
                circuitOpen = true
            }
            throw MCPError.protocolError("Empty result from MCP server.")
        }

        failureCount = 0
        circuitOpen = false
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
