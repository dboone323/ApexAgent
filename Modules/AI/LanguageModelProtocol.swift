import Foundation

public protocol LanguageModelProtocol: Actor {
    var modelID: String { get }
    var isAvailable: Bool { get async }

    func complete(
        _ request: ModelRequest
    ) async throws(ModelRouterError) -> ModelResponse

    func stream(
        _ request: ModelRequest
    ) -> AsyncThrowingStream<ModelChunk, Error>
}
