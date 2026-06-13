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

        // Check if we exceeded the tool call limit for this active turn (safety throttle)
        let overLimit = await MainActor.run {
            let limit = orchestrator.orchestrator.multiAgentModeEnabled ? 20 : 4
            return orchestrator.orchestrator.activeTurnToolCallCount > limit
        }
        if overLimit {
            let limit = await MainActor.run { orchestrator.orchestrator.multiAgentModeEnabled == true ? 20 : 4 }
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
            let maxLength = 1000
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
