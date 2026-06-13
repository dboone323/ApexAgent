import Foundation
import FoundationModels

struct RunWorkflowTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "run_workflow"
    let description = "Runs a structured explicit workflow (Codex -> Auditor -> Nexus) to implement code changes, lint them, and verify compilation."
    
    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The coding task or goal to accomplish.")
        var task: String
    }
    
    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orchestrator = await self.orchestrator.orchestrator
            return try await orchestrator.runExplicitCodingWorkflow(topic: arguments.task)
        }
    }
}
