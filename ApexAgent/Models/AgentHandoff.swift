import Foundation
import FoundationModels

// MARK: - Agent Handoff Protocol

public protocol AgentHandoff: Sendable {
    var context: TaskContext { get }
    var result: TaskResult? { get }
}

// MARK: - Task Context DTO

@Generable
public struct TaskContext: Codable, Sendable {
    @Guide(description: "Unique string identifier for this task execution")
    public var taskId: String
    
    @Guide(description: "The name of the task or short description")
    public var topic: String
    
    @Guide(description: "Detailed instructions and context for the task")
    public var instructions: String
    
    @Guide(description: "Relevant historical context or previous execution summary")
    public var contextHistory: String?

    public init(taskId: String = UUID().uuidString, topic: String, instructions: String, contextHistory: String? = nil) {
        self.taskId = taskId
        self.topic = topic
        self.instructions = instructions
        self.contextHistory = contextHistory
    }
}

// MARK: - Task Result DTO

@Generable
public struct TaskResult: Codable, Sendable {
    @Guide(description: "Unique identifier matching the TaskContext")
    public var taskId: String
    
    @Guide(description: "Status of the execution: completed, failed, or partially_completed")
    public var status: String
    
    @Guide(description: "Detailed textual result, summary of work done, or files edited")
    public var resultSummary: String
    
    @Guide(description: "Error message if the task failed")
    public var errorDetails: String?

    public init(taskId: String, status: String, resultSummary: String, errorDetails: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.resultSummary = resultSummary
        self.errorDetails = errorDetails
    }
}

// MARK: - Agent Disagreement DTO

@Generable
public struct AgentDisagreement: Codable, Sendable {
    @Guide(description: "Task or topic the agents are discussing")
    public var topic: String
    
    @Guide(description: "List of conflicting opinions as key-value pairs of 'AgentName: Position'")
    public var agentPositions: [String]
    
    @Guide(description: "Reasoning or explanation of the conflict")
    public var conflictSummary: String

    public init(topic: String, agentPositions: [String], conflictSummary: String) {
        self.topic = topic
        self.agentPositions = agentPositions
        self.conflictSummary = conflictSummary
    }
}

// MARK: - Consensus Report DTO

@Generable
public struct ConsensusReport: Codable, Sendable {
    @Guide(description: "The final decided action or conclusion")
    public var consensusDecision: String
    
    @Guide(description: "Summary of the majority view")
    public var majorityView: String
    
    @Guide(description: "Summary of the minority view or dissenting opinions")
    public var minorityDissent: String?
    
    @Guide(description: "Confidence level in the consensus, range 0.0 to 1.0")
    public var confidence: Double

    public init(consensusDecision: String, majorityView: String, minorityDissent: String? = nil, confidence: Double) {
        self.consensusDecision = consensusDecision
        self.majorityView = majorityView
        self.minorityDissent = minorityDissent
        self.confidence = confidence
    }
}
