import Foundation

public protocol MCPServerProtocol: Actor {
    var serverName: String { get }
    var port: Int { get }
    var tools: [MCPTool] { get }
    func handle(request: MCPRequest) async throws -> MCPToolResult
    func start() async throws
    func stop() async
}
