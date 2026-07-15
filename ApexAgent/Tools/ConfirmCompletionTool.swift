import Foundation
import FoundationModels

struct ConfirmCompletionTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "confirm_completion"
    let description = """
    Informs the user that the task is complete and requests final approval. \
    Provide a detailed summary of what was completed, list of files modified, \
    and validation/testing results. If the user approves, the task is marked done. \
    If denied, the user will specify further changes needed.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "A comprehensive summary of the changes and actions completed.")
        var summary: String

        @Guide(description: "Comma-separated list of file paths that were modified or created, if any.")
        var filesModified: String?

        @Guide(description: "Detailed description of how the changes were verified/tested.")
        var verificationResults: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orch = await orchestrator.orchestrator
            
            let displayArgs = """
            Summary: \(arguments.summary)
            Files Modified: \(arguments.filesModified ?? "None")
            Verification: \(arguments.verificationResults ?? "None")
            """
            
            let approved = await orch.requestConfirmation(
                toolName: self.name,
                arguments: displayArgs,
                riskDescription: "This will complete the task and finalize execution. Do you approve of the work done?"
            )
            
            if approved {
                return "SUCCESS: The user has approved task completion. You may now stop and output the final response."
            } else {
                return "DENIED: The user did NOT approve task completion. Please ask the user for feedback and continue working on the remaining or corrected items."
            }
        }
    }
}
