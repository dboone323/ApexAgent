import Foundation

public struct ModelMessage: Sendable, Codable {
    public let role: String
    public let content: String

    public static func system(_ content: String) -> ModelMessage {
        ModelMessage(role: "system", content: content)
    }

    public static func user(_ content: String) -> ModelMessage {
        ModelMessage(role: "user", content: content)
    }

    public static func assistant(_ content: String) -> ModelMessage {
        ModelMessage(role: "assistant", content: content)
    }
}

public struct ModelRequest: Sendable {
    public let messages: [ModelMessage]
    public let systemPrompt: String?
    public let temperature: Double
    public let maxTokens: Int
    public let thinkingMode: Bool
    public let outputSchema: (any Generable.Type)?
    public let privacyTier: PrivacyTier
    public let taskType: TaskType

    public enum PrivacyTier: Sendable {
        case sensitive
        case standard
        case unrestricted
    }

    public enum TaskType: Sendable, CustomStringConvertible {
        case generalReasoning
        case codeGeneration
        case codeReview
        case intentClassification
        case taskDecomposition
        case memoryQuery

        public var description: String {
            switch self {
            case .generalReasoning: "generalReasoning"
            case .codeGeneration: "codeGeneration"
            case .codeReview: "codeReview"
            case .intentClassification: "intentClassification"
            case .taskDecomposition: "taskDecomposition"
            case .memoryQuery: "memoryQuery"
            }
        }
    }

    public init(
        messages: [ModelMessage],
        systemPrompt: String? = nil,
        temperature: Double = 0.7,
        maxTokens: Int = 2048,
        thinkingMode: Bool = false,
        outputSchema: (any Generable.Type)? = nil,
        privacyTier: PrivacyTier = .standard,
        taskType: TaskType = .generalReasoning
    ) {
        self.messages = messages
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinkingMode = thinkingMode
        self.outputSchema = outputSchema
        self.privacyTier = privacyTier
        self.taskType = taskType
    }
}
