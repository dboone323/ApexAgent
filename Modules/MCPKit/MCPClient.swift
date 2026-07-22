import Foundation

public actor MCPClient {
    private let serverURL: URL
    private let session: URLSession

    public init(serverURL: URL, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.session = session
    }

    public func listTools() async throws -> [MCPTool] {
        var request = URLRequest(url: serverURL.appendingPathComponent("tools"))
        request.httpMethod = "GET"
        
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode([MCPTool].self, from: data)
    }

    public func call(
        tool: String,
        arguments: [String: MCPValue]
    ) async throws -> MCPToolResult {
        var request = URLRequest(url: serverURL.appendingPathComponent("tools/call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mcpRequest = MCPRequest(
            method: "tools/call",
            params: MCPRequestParams(name: tool, arguments: arguments),
            id: 1
        )
        request.httpBody = try JSONEncoder().encode(mcpRequest)

        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(MCPToolResult.self, from: data)
    }

    public func callTyped<T: Decodable>(
        tool: String,
        arguments: [String: MCPValue],
        returning: T.Type
    ) async throws -> T {
        let result = try await call(tool: tool, arguments: arguments)
        if result.isError {
            throw NSError(domain: "MCPClientError", code: 1, userInfo: [NSLocalizedDescriptionKey: "MCP tool returned error"])
        }
        guard let firstText = result.content.first(where: { $0.type == "text" })?.text else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "No text content in tool result"))
        }
        guard let data = firstText.data(using: .utf8) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: [], debugDescription: "Failed to convert tool result text to data"))
        }
        return try JSONDecoder().decode(returning, from: data)
    }
}
