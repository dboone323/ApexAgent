import Foundation
import FoundationModels

extension Tool {
    /// Executes the tool logic with built-in start/end event logging and safety confirmation gates.
    func executeWithLogging(
        arguments: Any,
        orchestrator: OrchestratorProvider,
        riskDescription: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil,
        body: () async throws -> String
    ) async throws -> String {
        let toolName = self.name
        let argsString = String(describing: arguments)

        // Log starting of the tool
        await orchestrator.orchestrator.logToolStart(name: toolName, arguments: argsString)

        let overLimit = await MainActor.run {
            let limit = 20
            return orchestrator.orchestrator.activeTurnToolCallCount > limit
        }
        if overLimit {
            let limit = 20
            let limitMsg = "ERROR: Maximum tool calls (\(limit)) reached for this turn to prevent context window overflow."
            await MainActor.run {
                orchestrator.orchestrator.logToolEnd(name: toolName, result: limitMsg, status: .failed("Tool call limit reached"))
            }
            return limitMsg
        }

        // Check if user confirmation is required (safety gate)
        let needsConfirm = await orchestrator.orchestrator.shouldConfirmTool(name: toolName)
        if needsConfirm {
            await orchestrator.orchestrator.updateToolStatus(name: toolName, status: .awaitingConfirmation)
            let approved = await orchestrator.orchestrator.requestConfirmation(
                toolName: toolName,
                arguments: argsString,
                riskDescription: riskDescription ?? "Potentially risky system operation",
                oldContent: oldContent,
                newContent: newContent,
                filePath: filePath
            )

            if !approved {
                await orchestrator.orchestrator.logToolEnd(name: toolName, result: "Operation denied by user.", status: .denied)
                return "ERROR: Operation denied by user."
            }
        }

        // Set status to running once approved
        await orchestrator.orchestrator.updateToolStatus(name: toolName, status: .running)

        do {
            var result = try await body()

            // Centralized Tool Output Truncation to optimize token usage
            let maxLength = 8000
            if result.count > maxLength {
                result = String(result.prefix(maxLength)) + "\n\n[... output truncated at \(maxLength) characters to optimize token usage ...]"
            }

            await orchestrator.orchestrator.logToolEnd(name: toolName, result: result, status: .success)
            return result
        } catch {
            let errorMsg = "ERROR: \(error.localizedDescription)"
            await orchestrator.orchestrator.logToolEnd(name: toolName, result: errorMsg, status: .failed(error.localizedDescription))
            return errorMsg
        }
    }
}

struct AnyExecutableTool: Sendable {
    let name: String
    let schemaJSON: String?
    private let _execute: @Sendable (String) async throws -> String

    init<T: Tool>(_ tool: T) where T.Arguments: Decodable, T.Output == String, T: Sendable {
        self.name = tool.name
        self._execute = { jsonArguments in
            let decoder = JSONDecoder()
            guard let data = jsonArguments.data(using: .utf8) else {
                throw NSError(domain: "Tool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON arguments"])
            }
            let args = try decoder.decode(T.Arguments.self, from: data)
            return try await tool.call(arguments: args)
        }
        
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(tool.parameters),
           let jsonStr = String(data: data, encoding: .utf8) {
            // Reconstruct tool schema JSON with name/description
            let dict: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "parameters": (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            ]
            if let finalData = try? JSONSerialization.data(withJSONObject: dict),
               let finalStr = String(data: finalData, encoding: .utf8) {
                self.schemaJSON = finalStr
            } else {
                self.schemaJSON = jsonStr
            }
        } else {
            self.schemaJSON = nil
        }
    }

    @ToolActor
    func execute(jsonArguments: String) async throws -> String {
        return try await _execute(jsonArguments)
    }
}
