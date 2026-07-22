import Foundation
import SharedModels

public protocol Generable: Codable, Sendable {
    static func decode(from data: Data) throws -> Self
}

public extension Generable {
    static func decode(from data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum SubAgentTarget: String, Codable, Sendable {
    case codingAgent
    case plannerAgent
    case memoryAgent
    case systemAgent
}

public struct AgentStep: Codable, Sendable {
    public let stepNumber: Int
    public let description: String

    public init(stepNumber: Int, description: String) {
        self.stepNumber = stepNumber
        self.description = description
    }
}

public struct TaskItem: Codable, Sendable {
    public let title: String
    public let detail: String
    public var estimatedHours: Double?

    public init(title: String, detail: String, estimatedHours: Double? = nil) {
        self.title = title
        self.detail = detail
        self.estimatedHours = estimatedHours
    }
}

public enum AgentIntent: String, Codable, Sendable {
    case chat
    case codeReview
    case codeGeneration
    case taskPlanning
    case searchMemory
    case systemCommand
}

// Conforming the models and structured schemas to Generable
extension CodeReviewResult: Generable {}

public struct AgentPlan: Generable {
    public let selectedTool: String
    public let subAgentTarget: SubAgentTarget?
    public let steps: [AgentStep]
    public let reasoning: String
    public let requiresThinking: Bool

    public init(selectedTool: String, subAgentTarget: SubAgentTarget?, steps: [AgentStep], reasoning: String, requiresThinking: Bool) {
        self.selectedTool = selectedTool
        self.subAgentTarget = subAgentTarget
        self.steps = steps
        self.reasoning = reasoning
        self.requiresThinking = requiresThinking
    }
}

public struct TaskBreakdown: Generable {
    public let tasks: [TaskItem]
    public let estimatedHours: Double
    public let sprintRecommendation: String
    public let dependencies: [String]

    public init(tasks: [TaskItem], estimatedHours: Double, sprintRecommendation: String, dependencies: [String]) {
        self.tasks = tasks
        self.estimatedHours = estimatedHours
        self.sprintRecommendation = sprintRecommendation
        self.dependencies = dependencies
    }
}

public struct IntentClassification: Generable {
    public let intent: AgentIntent
    public let confidence: Double
    public let targetSubAgent: SubAgentTarget?
    public let requiresUserConfirmation: Bool

    public init(intent: AgentIntent, confidence: Double, targetSubAgent: SubAgentTarget?, requiresUserConfirmation: Bool) {
        self.intent = intent
        self.confidence = confidence
        self.targetSubAgent = targetSubAgent
        self.requiresUserConfirmation = requiresUserConfirmation
    }
}
