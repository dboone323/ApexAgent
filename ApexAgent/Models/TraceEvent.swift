import Foundation

struct TraceEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let source: String
    let operation: String
    let detail: String
    let durationMs: TimeInterval?
    let metadata: [String: String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: String,
        operation: String,
        detail: String = "",
        durationMs: TimeInterval? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.operation = operation
        self.detail = detail
        self.durationMs = durationMs
        self.metadata = metadata
    }

    var category: String { source }
    var message: String { detail }
}
