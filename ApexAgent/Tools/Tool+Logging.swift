import Foundation
import FoundationModels

extension Tool {
    /// Executes the tool logic with built-in start/end event logging and safety confirmation gates.
    func executeWithLogging(
        arguments: Any,
        riskDescription: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil,
        body: () async throws -> String
    ) async throws -> String {
        let toolName = self.name
        let argsString = String(describing: arguments)

        // Log starting of the tool
        await AgentOrchestrator.shared?.logToolStart(name: toolName, arguments: argsString)

        // Check if we exceeded the tool call limit for this active turn (safety throttle)
        let overLimit = await MainActor.run {
            guard let orchestrator = AgentOrchestrator.shared else { return false }
            let limit = orchestrator.multiAgentModeEnabled ? 20 : 4
            return orchestrator.activeTurnToolCallCount > limit
        }
        if overLimit {
            let limit = await MainActor.run { AgentOrchestrator.shared?.multiAgentModeEnabled == true ? 20 : 4 }
            let limitMsg = "ERROR: Maximum tool calls (\(limit)) reached for this turn to prevent context window overflow."
            await MainActor.run {
                AgentOrchestrator.shared?.logToolEnd(name: toolName, result: limitMsg, status: .failed("Tool call limit reached"))
            }
            return limitMsg
        }

        // Check if user confirmation is required (safety gate)
        let needsConfirm = await AgentOrchestrator.shared?.shouldConfirmTool(name: toolName) ?? false
        if needsConfirm {
            await AgentOrchestrator.shared?.updateToolStatus(name: toolName, status: .awaitingConfirmation)
            let approved = await AgentOrchestrator.shared?.requestConfirmation(
                toolName: toolName,
                arguments: argsString,
                riskDescription: riskDescription ?? "Potentially risky system operation",
                oldContent: oldContent,
                newContent: newContent,
                filePath: filePath
            ) ?? false

            if !approved {
                await AgentOrchestrator.shared?.logToolEnd(name: toolName, result: "Operation denied by user.", status: .denied)
                return "ERROR: Operation denied by user."
            }
        }

        // Set status to running once approved
        await AgentOrchestrator.shared?.updateToolStatus(name: toolName, status: .running)

        do {
            var result = try await body()
            
            // Centralized Tool Output Truncation to optimize token usage
            let maxLength = 1000
            if result.count > maxLength {
                result = String(result.prefix(maxLength)) + "\n\n[... output truncated at \(maxLength) characters to optimize token usage ...]"
            }
            
            await AgentOrchestrator.shared?.logToolEnd(name: toolName, result: result, status: .success)
            return result
        } catch {
            let errorMsg = "ERROR: \(error.localizedDescription)"
            await AgentOrchestrator.shared?.logToolEnd(name: toolName, result: errorMsg, status: .failed(error.localizedDescription))
            return errorMsg
        }
    }
}
