import Foundation
import Network

public actor MCPServerListener {
    private let port: Int
    private let tools: @Sendable () async -> [MCPTool]
    private let handler: @Sendable (MCPRequest) async throws -> MCPToolResult
    
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]

    public init(
        port: Int,
        tools: @escaping @Sendable () async -> [MCPTool],
        handler: @escaping @Sendable (MCPRequest) async throws -> MCPToolResult
    ) {
        self.port = port
        self.tools = tools
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port))!
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.handleConnection(connection)
            }
        }

        listener.start(queue: .global())
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        buffers.removeAll()
    }

    private func handleConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global())
        readNextMessage(connection, id: id)
    }

    private func readNextMessage(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task {
                    await self.appendAndProcess(data: data, id: id, connection: connection)
                    if !isComplete && error == nil {
                        await self.readNextMessage(connection, id: id)
                    }
                }
            } else {
                Task { await self.removeConnection(id) }
            }
        }
    }

    private func removeConnection(_ id: UUID) {
        connections.removeValue(forKey: id)
        buffers.removeValue(forKey: id)
    }

    private func appendAndProcess(data: Data, id: UUID, connection: NWConnection) async {
        var buffer = buffers[id] ?? Data()
        buffer.append(data)
        buffers[id] = buffer
        
        guard let httpString = String(data: buffer, encoding: .utf8) else {
            return
        }
        
        guard let headerEndRange = httpString.range(of: "\r\n\r\n") else {
            return
        }
        
        let headersString = String(httpString[..<headerEndRange.lowerBound])
        
        var contentLength = 0
        let lines = headersString.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1]) ?? 0
            }
        }
        
        let headerDataLength = headersString.data(using: .utf8)?.count ?? 0
        let doubleCrlfLength = 4
        let totalExpectedLength = headerDataLength + doubleCrlfLength + contentLength
        
        if buffer.count < totalExpectedLength {
            return
        }
        
        let requestBodyData = buffer.subdata(in: (headerDataLength + doubleCrlfLength)..<totalExpectedLength)
        buffers.removeValue(forKey: id)
        
        await processRequest(headersString: headersString, bodyData: requestBodyData, connection: connection)
    }

    private func processRequest(headersString: String, bodyData: Data, connection: NWConnection) async {
        let lines = headersString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return }
        let requestParts = firstLine.components(separatedBy: " ")
        guard requestParts.count >= 2 else { return }
        let path = requestParts[1]
        
        if path == "/tools" {
            do {
                let currentTools = await tools()
                let resultData = try JSONEncoder().encode(currentTools)
                sendResponse(statusCode: 200, statusText: "OK", body: resultData, connection: connection)
            } catch {
                sendError(connection)
            }
        } else if path == "/tools/call" {
            do {
                let mcpRequest = try JSONDecoder().decode(MCPRequest.self, from: bodyData)
                let result = try await handler(mcpRequest)
                let resultData = try JSONEncoder().encode(result)
                sendResponse(statusCode: 200, statusText: "OK", body: resultData, connection: connection)
            } catch {
                sendError(connection)
            }
        } else {
            sendResponse(statusCode: 404, statusText: "Not Found", body: Data(), connection: connection)
        }
    }

    private func sendResponse(statusCode: Int, statusText: String, body: Data, connection: NWConnection) {
        let headers = [
            "HTTP/1.1 \(statusCode) \(statusText)",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close"
        ]
        let responseString = headers.joined(separator: "\r\n") + "\r\n\r\n"
        
        var responseData = responseString.data(using: .utf8)!
        responseData.append(body)

        connection.send(content: responseData, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendError(_ connection: NWConnection) {
        let errorResponse = "HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
        connection.send(content: errorResponse.data(using: .utf8)!, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
}
