import Foundation
import FoundationModels

struct RunWorkflowTool: Tool {
    let name = "run_workflow"
    let description = "Runs a structured explicit workflow (Codex -> Auditor -> Nexus) to implement code changes, lint them, and verify compilation."
    
    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The coding task or goal to accomplish.")
        var task: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            guard let orchestrator = await AgentOrchestrator.shared else {
                return "ERROR: AgentOrchestrator is not available"
            }
            return try await orchestrator.runExplicitCodingWorkflow(topic: arguments.task)
        }
    }
}
