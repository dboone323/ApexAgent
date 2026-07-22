import Foundation

public actor OllamaProvider: LanguageModelProtocol {
    public let modelID: String
    private let client: OllamaClient

    init(modelID: String, client: OllamaClient) {
        self.modelID = modelID
        self.client = client
    }

    public var isAvailable: Bool {
        get async {
            do {
                let models = try await client.listModels()
                return models.contains(where: { $0.name.contains(modelID) })
            } catch {
                return false
            }
        }
    }

    public func complete(_ request: ModelRequest) async throws(ModelRouterError) -> ModelResponse {
        let startTime = Date()
        do {
            let format = request.outputSchema != nil ? OllamaFormat.json : nil
            let response = try await client.generate(
                model: modelID,
                messages: request.messages,
                stream: false,
                format: format
            )
            let latency = Date().timeIntervalSince(startTime) * 1000.0

            var structured: (any Sendable)? = nil
            if let schema = request.outputSchema, let data = response.message.content.data(using: .utf8) {
                do {
                    structured = try schema.decode(from: data)
                } catch {
                    throw ModelRouterError.decodingFailed("Failed to decode structured output: \(error.localizedDescription)")
                }
            }

            return ModelResponse(
                text: response.message.content,
                structured: structured,
                latencyMs: latency
            )
        } catch let error as ModelRouterError {
            throw error
        } catch {
            throw ModelRouterError.requestFailed(error.localizedDescription)
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelChunk, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await complete(request)
                    continuation.yield(ModelChunk(text: response.text))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
