import Foundation

/// Intentional integration seam, documented per AUDIT_2026-09-28 §3.4.34.
/// Currently has zero conformers: it defines the agreed contract for folding
/// ApexAgent's MCP server surfaces (HTTP gateway, stdio bridge) onto a single
/// shape. New server implementations should conform here; do not treat this
/// as accidental dead code — delete it only when the consolidation lands.
public protocol MCPServerProtocol: Actor {
    var serverName: String { get }
    var port: Int { get }
    var tools: [MCPTool] { get }
    func handle(request: MCPRequest) async throws -> MCPToolResult
    func start() async throws
    func stop() async
}
