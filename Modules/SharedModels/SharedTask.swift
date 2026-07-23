import Foundation

public struct SharedTask: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: String
    public var priority: String

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        status: String,
        priority: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.priority = priority
    }
}
