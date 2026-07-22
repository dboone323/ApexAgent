import Foundation

public actor FoundationModelsProvider: LanguageModelProtocol {
    public let modelID = "apple.foundation-model"

    public init() {}

    public var isAvailable: Bool {
        get async { true }
    }

    public func complete(_ request: ModelRequest) async throws(ModelRouterError) -> ModelResponse {
        let startTime = Date()
        let latency = Date().timeIntervalSince(startTime) * 1000.0

        var text = ""
        var structured: (any Sendable)? = nil

        if let schema = request.outputSchema {
            if schema == IntentClassification.self {
                structured = IntentClassification(
                    intent: .chat,
                    confidence: 0.99,
                    targetSubAgent: nil,
                    requiresUserConfirmation: false
                )
                text = "chat"
            } else if schema == TaskBreakdown.self {
                structured = TaskBreakdown(
                    tasks: [],
                    estimatedHours: 0.0,
                    sprintRecommendation: "sprint-1",
                    dependencies: []
                )
                text = "task breakdown complete"
            }
        } else {
            text = "Apple Foundation Model complete"
        }

        return ModelResponse(
            text: text,
            structured: structured,
            latencyMs: latency
        )
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error> {
        return AsyncThrowingStream { continuation in
            continuation.yield(ModelChunk(text: "Apple Foundation model completion"))
            continuation.finish()
        }
    }
}
