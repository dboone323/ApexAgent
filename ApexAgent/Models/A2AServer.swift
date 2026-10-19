import Foundation
import Network
import AppKit

// MARK: - A2A Agent Card
public struct A2AAgentCard: Codable, Sendable {
    public let name: String
    public let description: String
    public let version: String         // e.g. "1.0.0"
    public let url: String             // e.g. "http://localhost:1338"
    public let capabilities: A2ACapabilities
    public let skills: [A2ASkill]
    public let defaultInputModes: [String]   // e.g. ["text"]
    public let defaultOutputModes: [String]  // e.g. ["text"]
    
    public struct A2ACapabilities: Codable, Sendable {
        public let streaming: Bool
        public let pushNotifications: Bool
        public let stateTransitionHistory: Bool
    }
    
    public struct A2ASkill: Codable, Sendable {
        public let id: String
        public let name: String
        public let description: String
        public let tags: [String]
        public let inputModes: [String]
        public let outputModes: [String]
    }
}

// MARK: - A2A JSON-RPC Request/Response
public struct A2ARequest: Codable, Sendable {
    public let jsonrpc: String      // "2.0"
    public let id: String
    public let method: String       // "tasks/send", "tasks/get", "tasks/cancel"
    public let params: A2ATaskParams?
}

public struct A2ATaskParams: Codable, Sendable {
    public let id: String
    public let message: A2AMessage
    
    public struct A2AMessage: Codable, Sendable {
        public let role: String         // "user"
        public let parts: [A2APart]
        
        public struct A2APart: Codable, Sendable {
            public let type: String     // "text"
            public let text: String?
        }
    }
}

public struct A2AResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: String
    public let result: A2ATaskResult?
    public let error: A2AError?
    
    public struct A2ATaskResult: Codable, Sendable {
        public let id: String
        public let status: A2ATaskStatus
        public let artifacts: [A2AArtifact]
        
        public struct A2ATaskStatus: Codable, Sendable {
            public let state: String    // "completed", "failed", "working"
        }
        
        public struct A2AArtifact: Codable, Sendable {
            public let parts: [A2ATaskParams.A2AMessage.A2APart]
        }
    }
    
    public struct A2AError: Codable, Sendable {
        public let code: Int
        public let message: String
    }
}

@Observable
@MainActor
public final class A2AServer {
    public static let shared = A2AServer()
    
    public private(set) var port: UInt16
    private var listener: NWListener?
    weak var orchestrator: AgentOrchestrator?
    weak var botManager: BotManager?
    
    public private(set) var isRunning: Bool = false
    
    public init(port: UInt16 = 1338) {
        self.port = port
    }
    
    // Start the A2A HTTP server on specified port (default 1338)
    public func start(port: UInt16? = nil) throws {
        if let customPort = port {
            self.port = customPort
        }
        guard !isRunning else { return }
        
        let tcpOptions = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.allowLocalEndpointReuse = true
        
        guard let nwPort = NWEndpoint.Port(rawValue: self.port) else {
            throw NSError(domain: "A2AServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(self.port)"])
        }
        listener = try NWListener(using: parameters, on: nwPort)
        
        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                    AppLog.info(.a2a, "A2AServer running on port \(self?.port ?? 1338)")
                case .failed(let error):
                    AppLog.error(.a2a, "A2AServer failed with error: \(error)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: .main)
        // Mark running immediately upon successful start call so sync checks pass
        isRunning = true
    }
    
    // Stop the server
    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    // Build and return the Agent Card representing this ApexAgent instance
    public func buildAgentCard() -> A2AAgentCard {
        let skills: [A2AAgentCard.A2ASkill] = botManager?.allBots.map { bot in
            A2AAgentCard.A2ASkill(
                id: bot.id.uuidString,
                name: bot.name,
                description: bot.descriptionText,
                tags: [],
                inputModes: ["text"],
                outputModes: ["text"]
            )
        } ?? []
        
        return A2AAgentCard(
            name: "ApexAgent",
            description: "An instance of ApexAgent A2A node",
            version: "1.0.0",
            url: "http://localhost:\(port)",
            capabilities: A2AAgentCard.A2ACapabilities(
                streaming: false,
                pushNotifications: false,
                stateTransitionHistory: false
            ),
            skills: skills,
            defaultInputModes: ["text"],
            defaultOutputModes: ["text"]
        )
    }
    
    private nonisolated func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        
        // Read headers and body
        @Sendable func readLoop(buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error = error {
                    AppLog.error(.a2a, "A2AServer read error: \(error)")
                    connection.cancel()
                    return
                }
                
                var currentBuffer = buffer
                if let data = data {
                    currentBuffer.append(data)
                }
                
                Task {
                    if let (_, responseData) = await self.processHttpBuffer(currentBuffer) {
                        connection.send(content: responseData, completion: .contentProcessed({ _ in
                            connection.cancel()
                        }))
                    } else if !isComplete {
                        readLoop(buffer: currentBuffer)
                    } else {
                        connection.cancel()
                    }
                }
            }
        }
        
        readLoop(buffer: Data())
    }
    
    nonisolated func processHttpBuffer(_ buffer: Data) async -> (Data, Data)? {
        // Look for \r\n\r\n
        guard let headerEnd = buffer.range(of: Data([13, 10, 13, 10])) else {
            return nil // Incomplete headers
        }
        
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return (buffer, Data("HTTP/1.0 400 Bad Request\r\n\r\n".utf8))
        }
        
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            return (buffer, Data("HTTP/1.0 400 Bad Request\r\n\r\n".utf8))
        }
        let requestLine = firstLine.components(separatedBy: .whitespaces)
        guard requestLine.count >= 2 else {
            return (buffer, Data("HTTP/1.0 400 Bad Request\r\n\r\n".utf8))
        }
        let method = requestLine[0]
        let path = requestLine[1]
        
        let bodyStartIndex = headerEnd.upperBound
        var contentLength = 0
        var authHeader: String?
        
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                if name == "content-length" {
                    contentLength = Int(value) ?? 0
                } else if name == "authorization" {
                    authHeader = value
                }
            }
        }
        
        if buffer.count < bodyStartIndex + contentLength {
            return nil // Incomplete body
        }

        // Security check: If an A2A auth token is configured in Keychain, enforce Bearer auth on /a2a
        if path == "/a2a" {
            if let token = KeychainManager.get(key: "a2aAuthToken"), !token.isEmpty {
                let expected = "Bearer \(token)"
                if authHeader != expected {
                    let errBody = Data("{\"error\": \"Unauthorized\"}\n".utf8)
                    let errResponse = """
                    HTTP/1.1 401 Unauthorized\r
                    Content-Length: \(errBody.count)\r
                    Content-Type: application/json\r
                    Connection: close\r
                    \r
                    
                    """
                    var errFull = Data(errResponse.utf8)
                    errFull.append(errBody)
                    return (buffer, errFull)
                }
            }
        }
        
        let bodyData = buffer.subdata(in: bodyStartIndex..<bodyStartIndex + contentLength)
        let response = await self.handleRequest(method: method, path: path, body: bodyData)
        
        let responseString = """
        HTTP/1.1 200 OK\r
        Content-Length: \(response.count)\r
        Content-Type: application/json\r
        Connection: close\r
        \r
        
        """
        
        var fullResponse = Data(responseString.utf8)
        fullResponse.append(response)
        
        return (buffer, fullResponse)
    }

    // Handle incoming A2A requests
    private func handleRequest(method: String, path: String, body: Data) async -> Data {
        if method == "GET" && (path == "/health" || path == "/api/status") {
            let botCount = botManager?.allBots.count ?? 0
            let payload: [String: Any] = [
                "status": "healthy",
                "service": "ApexAgent A2A Node",
                "port": port,
                "running": isRunning,
                "activeBotsCount": botCount
            ]
            if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                return d
            }
            return Data("{\"status\":\"healthy\"}".utf8)
        }

        if method == "GET" && path == "/.well-known/agent.json" {
            let card = buildAgentCard()
            let encoder = JSONEncoder()
            return (try? encoder.encode(card)) ?? Data()
        }
        
        if method == "POST" && path == "/a2a" {
            let decoder = JSONDecoder()
            if let req = try? decoder.decode(A2ARequest.self, from: body) {
                let res = await processJsonRpc(req)
                let encoder = JSONEncoder()
                return (try? encoder.encode(res)) ?? Data()
            }
        }
        
        return Data()
    }
    
    private func processJsonRpc(_ req: A2ARequest) async -> A2AResponse {
        if req.method == "tasks/send", let params = req.params {
            let result = await handleTaskSend(params)
            return A2AResponse(jsonrpc: "2.0", id: req.id, result: result, error: nil)
        } else if req.method == "tasks/get", let params = req.params {
            let result = A2AResponse.A2ATaskResult(
                id: params.id,
                status: A2AResponse.A2ATaskResult.A2ATaskStatus(state: "completed"),
                artifacts: []
            )
            return A2AResponse(jsonrpc: "2.0", id: req.id, result: result, error: nil)
        } else {
            return A2AResponse(jsonrpc: "2.0", id: req.id, result: nil, error: A2AResponse.A2AError(code: -32601, message: "Method not found"))
        }
    }
    
    // Handle tasks/send — route to a bot and return result
        private func handleTaskSend(_ params: A2ATaskParams) async -> A2AResponse.A2ATaskResult {
        let textParts = params.message.parts.compactMap { $0.text }
        let combinedText = textParts.joined(separator: "\n")
        
        var replyText = "No bot available to handle request."
        
        if let botManager = botManager, let bot = botManager.allBots.first {
            let session = botManager.session(for: bot)
            replyText = await session.executeIsolatedTurn(prompt: combinedText) ?? "No response"
        }
        
        let artifact = A2AResponse.A2ATaskResult.A2AArtifact(parts: [
            A2ATaskParams.A2AMessage.A2APart(type: "text", text: replyText)
        ])
        
        return A2AResponse.A2ATaskResult(
            id: params.id,
            status: A2AResponse.A2ATaskResult.A2ATaskStatus(state: "completed"),
            artifacts: [artifact]
        )
    }
}

extension A2AAgentCard {
    public func formatAsMarkdown() -> String {
        var md = "### 📡 A2A Agent Card: \(name)\n\n"
        md += "- **Description**: \(description)\n"
        md += "- **Version**: `\(version)`\n"
        md += "- **Endpoint**: `\(url)`\n"
        md += "- **Capabilities**: streaming=\(capabilities.streaming ? "✅" : "⚪️"), push=\(capabilities.pushNotifications ? "✅" : "⚪️"), history=\(capabilities.stateTransitionHistory ? "✅" : "⚪️")\n"
        md += "- **Default Modes**: in=[\(defaultInputModes.joined(separator: ", "))], out=[\(defaultOutputModes.joined(separator: ", "))]\n"
        if skills.isEmpty {
            md += "\nNo skills advertised.\n"
        } else {
            md += "\n| Skill ID | Name | Description | Tags |\n"
            md += "|---|---|---|---|\n"
            for s in skills {
                let safeDesc = s.description.replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(s.id)` | **\(s.name)** | \(safeDesc) | \(s.tags.joined(separator: ", ")) |\n"
            }
        }
        return md
    }
}

extension A2AResponse {
    public func formatAsMarkdown() -> String {
        var md = "### 📨 A2A JSON-RPC Response: `\(id)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| JSON-RPC | `\(jsonrpc)` |\n"
        if let result {
            md += "| Task ID | `\(result.id)` |\n"
            md += "| State | `\(result.status.state)` |\n"
            md += "| Artifacts | `\(result.artifacts.count)` |\n"
            for (i, art) in result.artifacts.enumerated() {
                let text = art.parts.compactMap { $0.text }.joined(separator: " / ").prefix(160)
                md += "| Artifact \(i + 1) | \(text) |\n"
            }
        }
        if let error {
            md += "| Error | `\(error.code)` \(error.message.replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }
}
