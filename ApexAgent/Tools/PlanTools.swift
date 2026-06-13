import Foundation
import FoundationModels

// MARK: - Plan Step Model

struct PlanStep: Codable, Identifiable {
    var id = UUID()
    let title: String
    var status: String // "queued", "running", "completed", "failed"
    
    enum CodingKeys: String, CodingKey {
        case title
        case status
    }
}

// MARK: - Update Plan Tool

struct UpdatePlanTool: Tool {
    let name = "update_plan"
    let description = "Sets or updates the current execution plan steps to be visualized in the Plan Dashboard."

    @Generable
    struct Arguments: Decodable {
        @Generable
        struct Step: Decodable {
            var title: String
            var status: String
        }
        @Guide(description: "The list of plan steps")
        var steps: [Step]
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            await MainActor.run {
                guard let orchestrator = AgentOrchestrator.shared else {
                    return "ERROR: AgentOrchestrator is not available"
                }
                
                let newSteps = arguments.steps.map { step in
                    PlanStep(title: step.title, status: step.status)
                }
                
                orchestrator.activePlan = newSteps
                return "✅ Plan updated successfully with \(newSteps.count) steps."
            }
        }
    }
}
