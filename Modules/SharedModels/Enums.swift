import Foundation

public enum ProjectStatus: String, Codable, Sendable {
    case active
    case completed
    case archived
    case onHold
}

public enum TaskStatus: String, Codable, Sendable {
    case backlog
    case todo
    case inProgress
    case review
    case done
}

public enum TaskPriority: String, Codable, Sendable {
    case low
    case medium
    case high
    case critical
}

public enum SprintStatus: String, Codable, Sendable {
    case planned
    case active
    case completed
}

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public enum MemorySource: String, Codable, Sendable {
    case userChat
    case codeReview
    case planning
    case fileSystem
}

public enum ReviewSeverity: String, Codable, Sendable {
    case error
    case warning
    case info
}
