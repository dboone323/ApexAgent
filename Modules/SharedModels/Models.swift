import Foundation
import SwiftData

@Model
public final class ProjectModel {
    public var id: UUID
    public var name: String
    public var summary: String
    public var language: String
    public var repoURL: String?
    public var localPath: String?
    public var status: ProjectStatus
    public var createdAt: Date
    public var updatedAt: Date

    @Relationship(deleteRule: .cascade) public var tasks: [TaskModel]
    @Relationship(deleteRule: .cascade) public var sprints: [SprintModel]
    @Relationship(deleteRule: .cascade) public var reviewSessions: [ReviewSession]

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        language: String,
        repoURL: String? = nil,
        localPath: String? = nil,
        status: ProjectStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.language = language
        self.repoURL = repoURL
        self.localPath = localPath
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.tasks = []
        self.sprints = []
        self.reviewSessions = []
    }
}

@Model
public final class TaskModel {
    public var id: UUID
    public var title: String
    public var detail: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var estimatedHours: Double?
    public var actualHours: Double?
    public var tags: [String]
    public var createdAt: Date
    public var completedAt: Date?
    
    public var project: ProjectModel?
    public var sprint: SprintModel?

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String = "",
        status: TaskStatus = .backlog,
        priority: TaskPriority = .medium,
        estimatedHours: Double? = nil,
        actualHours: Double? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.priority = priority
        self.estimatedHours = estimatedHours
        self.actualHours = actualHours
        self.tags = tags
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

@Model
public final class SprintModel {
    public var id: UUID
    public var name: String
    public var goal: String
    public var startDate: Date
    public var endDate: Date
    public var status: SprintStatus
    public var createdAt: Date
    
    public var project: ProjectModel?
    @Relationship(deleteRule: .cascade) public var tasks: [TaskModel]

    public init(
        id: UUID = UUID(),
        name: String,
        goal: String = "",
        startDate: Date,
        endDate: Date,
        status: SprintStatus = .planned,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.startDate = startDate
        self.endDate = endDate
        self.status = status
        self.createdAt = createdAt
        self.tasks = []
    }
}

@Model
public final class CodeIssueModel {
    public var id: UUID
    public var line: Int
    public var message: String
    public var severity: ReviewSeverity
    public var session: ReviewSession?

    public init(
        id: UUID = UUID(),
        line: Int,
        message: String,
        severity: ReviewSeverity
    ) {
        self.id = id
        self.line = line
        self.message = message
        self.severity = severity
    }
}

// Temporary non-persistent wrapper matching @Generable structured output to support ReviewSession init
public struct CodeIssue: Codable, Sendable {
    public let line: Int
    public let message: String
    public let severity: ReviewSeverity
    
    public init(line: Int, message: String, severity: ReviewSeverity) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

public struct CodeReviewResult: Codable, Sendable {
    public let issues: [CodeIssue]
    public let suggestions: [String]
    public let severity: ReviewSeverity
    public let affectedLines: [Int]
    public let summary: String
    
    public init(issues: [CodeIssue], suggestions: [String], severity: ReviewSeverity, affectedLines: [Int], summary: String) {
        self.issues = issues
        self.suggestions = suggestions
        self.severity = severity
        self.affectedLines = affectedLines
        self.summary = summary
    }
}

@Model
public final class ReviewSession {
    public var id: UUID
    public var fileName: String
    public var summary: String
    public var suggestions: [String]
    public var createdAt: Date
    public var project: ProjectModel?
    
    @Relationship(deleteRule: .cascade) public var issues: [CodeIssueModel]

    public init(
        id: UUID = UUID(),
        fileName: String,
        summary: String,
        suggestions: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.summary = summary
        self.suggestions = suggestions
        self.createdAt = createdAt
        self.issues = []
    }

    public convenience init(
        fileName: String,
        result: CodeReviewResult,
        createdAt: Date = Date()
    ) {
        self.init(
            fileName: fileName,
            summary: result.summary,
            suggestions: result.suggestions,
            createdAt: createdAt
        )
        self.issues = result.issues.map { issue in
            CodeIssueModel(line: issue.line, message: issue.message, severity: issue.severity)
        }
    }
}

@Model
public final class AgentMemoryEntry {
    public var id: UUID
    public var content: String
    public var embedding: Data
    public var source: MemorySource
    public var relevanceScore: Double
    public var createdAt: Date
    public var lastAccessedAt: Date
    public var tags: [String]

    public init(
        id: UUID = UUID(),
        content: String,
        embedding: Data,
        source: MemorySource,
        relevanceScore: Double = 0.0,
        createdAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        tags: [String] = []
    ) {
        self.id = id
        self.content = content
        self.embedding = embedding
        self.source = source
        self.relevanceScore = relevanceScore
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
        self.tags = tags
    }
}

@Model
public final class AgentConversation {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var project: ProjectModel?
    
    @Relationship(deleteRule: .cascade) public var messages: [AgentMessage]

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = []
    }
}

@Model
public final class AgentMessage {
    public var id: UUID
    public var role: MessageRole
    public var userText: String
    public var responseText: String
    public var modelTier: String?
    public var createdAt: Date
    public var conversation: AgentConversation?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        userText: String = "",
        responseText: String = "",
        modelTier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.userText = userText
        self.responseText = responseText
        self.modelTier = modelTier
        self.createdAt = createdAt
    }
}
