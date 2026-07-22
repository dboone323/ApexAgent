import Foundation

public struct OllamaMessage: Codable, Sendable {
    public let role: String
    public let content: String
    
    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OllamaResponse: Codable, Sendable {
    public let model: String
    public let message: OllamaMessage
    public let done: Bool
    
    public init(model: String, message: OllamaMessage, done: Bool) {
        self.model = model
        self.message = message
        self.done = done
    }
}

public enum OllamaFormat: String, Codable, Sendable {
    case json
}

public struct OllamaModel: Codable, Sendable {
    public let name: String
    
    public init(name: String) {
        self.name = name
    }
}

public struct OllamaModelList: Codable, Sendable {
    public let models: [OllamaModel]
    
    public init(models: [OllamaModel]) {
        self.models = models
    }
}

actor OllamaClient {
    private let baseURL = URL(string: "http://localhost:11434")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generate(
        model: String,
        messages: [ModelMessage],
        stream: Bool = false,
        format: OllamaFormat? = nil
    ) async throws -> OllamaResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let ollamaMessages = messages.map { OllamaMessage(role: $0.role, content: $0.content) }
        var body: [String: AnySendable] = [
            "model": AnySendable(model),
            "messages": AnySendable(ollamaMessages),
            "stream": AnySendable(stream)
        ]
        if let format {
            body["format"] = AnySendable(format.rawValue)
        }

        request.httpBody = try JSONEncoder().encode(body)
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(OllamaResponse.self, from: data)
    }

    func loadModel(_ name: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["model": name]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }

    func unloadModel(_ name: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: AnyHashable] = ["model": name, "keep_alive": 0]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: request)
    }

    func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await session.data(from: url)
        let list = try JSONDecoder().decode(OllamaModelList.self, from: data)
        return list.models
    }
}

// A simple type-erased Sendable structure to help JSON serialization
struct AnySendable: Codable, Sendable {
    private let encodeValue: @Sendable (Encoder) throws -> Void

    init<T: Codable & Sendable>(_ value: T) {
        self.encodeValue = { try value.encode(to: $0) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }

    init(from decoder: Decoder) throws {
        fatalError("Decoding not supported")
    }
}
