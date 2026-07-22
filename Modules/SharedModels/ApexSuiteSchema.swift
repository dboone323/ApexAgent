import Foundation
import SwiftData

public enum ApexSuiteSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)
    public static let models: [any PersistentModel.Type] = [
        ProjectModel.self,
        TaskModel.self,
        SprintModel.self,
        ReviewSession.self,
        CodeIssueModel.self,
        AgentMemoryEntry.self,
        AgentConversation.self,
        AgentMessage.self,
    ]
}

public enum ApexSuiteMigrationPlan: SchemaMigrationPlan {
    public static let schemas: [any VersionedSchema.Type] = [ApexSuiteSchemaV1.self]
    public static let stages: [MigrationStage] = []
}
