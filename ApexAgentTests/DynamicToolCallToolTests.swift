import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 4: DynamicToolCallTool Tests", .serialized)
struct DynamicToolCallToolTests {

    @Test("DynamicToolCallTool metadata check")
    @MainActor
    func testDynamicToolCallToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DynamicToolCallTool(orchestrator: orchestrator)
        #expect(tool.name == "execute_dynamic_tool")
        #expect(tool.description.contains("Executes a dynamic tool"))
    }

    @Test("DynamicToolCallTool returns error when tool is not registered")
    @MainActor
    func testNonExistentTool() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DynamicToolCallTool(orchestrator: orchestrator)

        let args = DynamicToolCallTool.Arguments(
            toolName: "non_existent_tool_12345",
            jsonArguments: "{}"
        )
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: Tool 'non_existent_tool_12345' not found in dynamic tools registry."))
    }

    @Test("DynamicToolCallTool executes registered MCP tool entry")
    @MainActor
    func testDynamicToolboxRegistration() {
        let toolbox = DynamicToolbox.shared
        let schema = MCPToolDefinition(
            name: "sample_test_mcp_tool",
            description: "A test tool",
            inputSchema: MCPInputSchema(type: "object", properties: [:], required: [])
        )
        let serverId = UUID()
        toolbox.registerMCPTool(schema, serverId: serverId, serverName: "TestServer")

        #expect(toolbox.dynamicTools["sample_test_mcp_tool"] != nil)
        #expect(toolbox.dynamicTools["sample_test_mcp_tool"]?.name == "sample_test_mcp_tool")
    }
}
