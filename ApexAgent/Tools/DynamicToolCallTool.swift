import Foundation
import FoundationModels

struct DynamicToolCallTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "execute_dynamic_tool"
    let description = "Executes a dynamic tool or MCP tool by name with JSON arguments. Returns the tool output."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The name of the dynamic tool or MCP tool to execute.")
        var toolName: String

        @Guide(description: "JSON string containing arguments for the tool.")
        var jsonArguments: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let exists = await MainActor.run {
                DynamicToolbox.shared.dynamicTools[arguments.toolName] != nil
            }
            if exists {
                return try await DynamicToolbox.shared.executeTool(name: arguments.toolName, jsonArguments: arguments.jsonArguments)
            } else {
                return "ERROR: Tool '\(arguments.toolName)' not found in dynamic tools registry."
            }
        }
    }
}
