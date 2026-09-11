import Foundation
import FoundationModels

enum PlanStepStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case completed
    case failed
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self).lowercased()
        if let val = PlanStepStatus(rawValue: raw) {
            self = val
        } else {
            self = .queued
        }
    }
}

// MARK: - Plan Step Model

struct PlanStep: Codable, Identifiable {
    var id = UUID()
    let title: String
    var status: PlanStepStatus
    var result: String?
    var error: String?
    
    enum CodingKeys: String, CodingKey {
        case title
        case status
        case result
        case error
    }
}

// MARK: - Update Plan Tool

struct UpdatePlanTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    let name = "update_plan"
    let description = "Sets or updates the current execution plan steps to be visualized in the Plan Dashboard."

    @Generable
    struct Arguments: Decodable {
        @Generable
        struct Step: Decodable {
            var title: String
            var status: String
            var result: String?
            var error: String?
        }
        @Guide(description: "The list of plan steps")
        var steps: [Step]
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let orchestrator = self.orchestrator.orchestrator
                
                let newSteps = arguments.steps.map { step in
                    let parsedStatus = PlanStepStatus(rawValue: step.status.lowercased()) ?? .queued
                    return PlanStep(title: step.title, status: parsedStatus, result: step.result, error: step.error)
                }
                
                orchestrator.updatePlan(steps: newSteps)
                return "✅ Plan updated successfully with \(newSteps.count) steps."
            }
        }
    }
}
