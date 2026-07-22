import Foundation
import SharedLogging

public enum OllamaModelID: String, Sendable {
    case qwen3_8b = "qwen3:8b"
    case qwen25Coder7b = "qwen2.5-coder:7b"
    case qwen3_4b = "qwen3:4b"
}

public actor ModelRouter {
    public static let shared = ModelRouter()

    private let foundationModel = FoundationModelsProvider()

    private let ollamaQwen3_8b: OllamaProvider
    private let ollamaQwen25Coder: OllamaProvider
    private let ollamaQwen3_4b: OllamaProvider

    private let ollamaClient = OllamaClient()
    private var residentModel: OllamaModelID?

    private init() {
        self.ollamaQwen3_8b = OllamaProvider(modelID: OllamaModelID.qwen3_8b.rawValue, client: ollamaClient)
        self.ollamaQwen25Coder = OllamaProvider(modelID: OllamaModelID.qwen25Coder7b.rawValue, client: ollamaClient)
        self.ollamaQwen3_4b = OllamaProvider(modelID: OllamaModelID.qwen3_4b.rawValue, client: ollamaClient)
    }

    public func complete(
        _ request: ModelRequest
    ) async throws(ModelRouterError) -> ModelResponse {
        let provider = try await selectProvider(for: request)
        let modelID = await provider.modelID
        let response = try await provider.complete(request)
        SharedLogger.ai.info(
            "Routed: \(request.taskType) → \(modelID), latency: \(response.latencyMs)ms"
        )
        return response
    }

    public func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let provider = try await selectProvider(for: request)
                    let modelStream = await provider.stream(request)
                    for try await chunk in modelStream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func selectProvider(
        for request: ModelRequest
    ) async throws(ModelRouterError) -> any LanguageModelProtocol {
        if request.privacyTier == .sensitive { return foundationModel }

        switch request.taskType {
        case .intentClassification, .memoryQuery:
            return foundationModel

        case .codeGeneration, .codeReview:
            try await ensureResident(.qwen25Coder7b)
            return ollamaQwen25Coder

        case .generalReasoning, .taskDecomposition:
            try await ensureResident(.qwen3_8b)
            return ollamaQwen3_8b
        }
    }

    private func ensureResident(_ model: OllamaModelID) async throws(ModelRouterError) {
        guard residentModel != model else { return }
        if let current = residentModel {
            do {
                try await ollamaClient.unloadModel(current.rawValue)
            } catch {
                throw ModelRouterError.requestFailed("Failed to unload resident model: \(error.localizedDescription)")
            }
        }
        do {
            try await ollamaClient.loadModel(model.rawValue)
        } catch {
            throw ModelRouterError.requestFailed("Failed to load resident model: \(error.localizedDescription)")
        }
        residentModel = model
    }
}
