import Foundation

public struct ModelChunk: Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct ModelResponse: Sendable {
    public let text: String
    public let structured: (any Sendable)?
    public let latencyMs: Double

    public init(text: String, structured: (any Sendable)? = nil, latencyMs: Double) {
        self.text = text
        self.structured = structured
        self.latencyMs = latencyMs
    }
}

public enum ModelRouterError: Error, Sendable {
    case modelUnavailable(String)
    case requestFailed(String)
    case decodingFailed(String)
    case invalidRequest(String)
}
