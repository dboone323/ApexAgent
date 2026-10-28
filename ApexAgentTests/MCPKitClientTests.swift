import Testing
import Foundation
import MCPKit

final class MockMCPURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockMCPURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockMCPURLProtocol", code: -1, userInfo: [NSLocalizedDescriptionKey: "No handler configured"]))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func extractBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let bytesRead = stream.read(&buffer, maxLength: buffer.count)
                if bytesRead > 0 {
                    data.append(buffer, count: bytesRead)
                } else {
                    break
                }
            }
            return data
        }
        return nil
    }
}

@Suite("Batch 2: MCPKit.MCPClient Tests", .serialized)
struct MCPKitClientTests {

    private func makeTestClient() -> (MCPKit.MCPClient, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockMCPURLProtocol.self]
        let session = URLSession(configuration: config)
        let baseURL = URL(string: "http://127.0.0.1:8999")!
        let client = MCPKit.MCPClient(serverURL: baseURL, session: session)
        return (client, baseURL)
    }

    @Test("MCPClient initializes with custom URLSession configuration")
    func testInitialization() async throws {
        let (client, baseURL) = makeTestClient()
        // Verify actor accessibility and client initialization by executing a clean listTools request
        MockMCPURLProtocol.requestHandler = { request in
            let emptyTools: [MCPTool] = []
            let data = try! JSONEncoder().encode(emptyTools)
            let response = HTTPURLResponse(
                url: request.url ?? baseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }
        let tools = try await client.listTools()
        #expect(tools.isEmpty)
    }

    @Test("listTools issues GET /tools request and decodes tools array")
    func testListTools() async throws {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/tools")

            let tool = MCPTool.make(
                name: "file_search",
                description: "Search workspace files",
                inputs: [.string("pattern", description: "Search glob", required: true)]
            )
            let data = try JSONEncoder().encode([tool])
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools[0].name == "file_search")
        #expect(tools[0].description == "Search workspace files")
        #expect(tools[0].inputSchema.properties["pattern"]?.type == "string")
    }

    @Test("call issues POST /tools/call with encoded MCPRequest and returns result")
    func testCall() async throws {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/tools/call")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let bodyData = MockMCPURLProtocol.extractBodyData(from: request) ?? Data()
            let decoded = try JSONDecoder().decode(MCPRequest.self, from: bodyData)
            #expect(decoded.method == "tools/call")
            #expect(decoded.params?.name == "echo_tool")
            #expect(decoded.params?.arguments?["message"] == .string("test input"))

            let result = MCPToolResult(content: [MCPContent(text: "Echo: test input")], isError: false)
            let respData = try JSONEncoder().encode(result)
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, respData)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        let result = try await client.call(tool: "echo_tool", arguments: ["message": .string("test input")])
        #expect(!result.isError)
        #expect(result.content.count == 1)
        #expect(result.content.first?.text == "Echo: test input")
    }

    struct EchoPayload: Codable, Equatable {
        let status: String
        let code: Int
    }

    @Test("callTyped successfully parses generic decodable response")
    func testCallTypedSuccess() async throws {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            let payload = EchoPayload(status: "healthy", code: 200)
            let jsonString = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
            let result = MCPToolResult(content: [MCPContent(text: jsonString)], isError: false)
            let data = try JSONEncoder().encode(result)
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        let typed = try await client.callTyped(tool: "health_check", arguments: [:], returning: EchoPayload.self)
        #expect(typed == EchoPayload(status: "healthy", code: 200))
    }

    @Test("callTyped throws error when tool result reports isError")
    func testCallTypedThrowsOnToolError() async {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            let result = MCPToolResult(content: [MCPContent(text: "Command execution failed")], isError: true)
            let data = try JSONEncoder().encode(result)
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        await #expect(throws: Error.self) {
            try await client.callTyped(tool: "failing_tool", arguments: [:], returning: EchoPayload.self)
        }
    }

    @Test("callTyped throws DecodingError on malformed JSON payload")
    func testCallTypedThrowsOnMalformedJSON() async {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            let result = MCPToolResult(content: [MCPContent(text: "Not valid JSON string")], isError: false)
            let data = try JSONEncoder().encode(result)
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        await #expect(throws: DecodingError.self) {
            try await client.callTyped(tool: "malformed_tool", arguments: [:], returning: EchoPayload.self)
        }
    }

    @Test("callTyped throws DecodingError when tool result has no text content")
    func testCallTypedThrowsWhenNoTextContent() async {
        let (client, baseURL) = makeTestClient()

        MockMCPURLProtocol.requestHandler = { request in
            let result = MCPToolResult(content: [], isError: false)
            let data = try JSONEncoder().encode(result)
            let response = HTTPURLResponse(url: request.url ?? baseURL, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, data)
        }
        defer { MockMCPURLProtocol.requestHandler = nil }

        await #expect(throws: DecodingError.self) {
            try await client.callTyped(tool: "empty_content_tool", arguments: [:], returning: EchoPayload.self)
        }
    }
}
