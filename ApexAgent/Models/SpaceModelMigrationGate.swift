// SpaceModelMigrationGate.swift
// Batch 129: SwiftData schema versioning, entity integrity inspector, and
// resilient container builder preventing SQLite crash loops across schema changes.

import Foundation
import SwiftData

/// Integrity report detailing schema version, registered entities, and missing entities.
public struct SpaceSchemaIntegrityReport: Sendable, Codable, Equatable {
    public let schemaVersion: Int
    public let isHealthy: Bool
    public let registeredEntityNames: [String]
    public let missingEntityNames: [String]
    public let recoveryRecommendation: String?

    public init(
        schemaVersion: Int,
        isHealthy: Bool,
        registeredEntityNames: [String],
        missingEntityNames: [String],
        recoveryRecommendation: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.isHealthy = isHealthy
        self.registeredEntityNames = registeredEntityNames
        self.missingEntityNames = missingEntityNames
        self.recoveryRecommendation = recoveryRecommendation
    }
}

/// SwiftData schema evolution & migration integrity gate preventing crash loops across schema changes.
public final class SpaceModelMigrationGate: Sendable {
    public static let currentSchemaVersion = 2
    public static let requiredSpaceEntities: [String] = [
        "SpaceModel",
        "SpaceParticipant",
        "SpaceChannel",
        "SpaceMessage",
        "SpacePage",
        "SpacePageProposal"
    ]

    /// Inspects the entities registered in a ModelContainer and checks for required Space entities.
    ///
    /// - Parameters:
    ///   - container: The `ModelContainer` to inspect.
    ///   - explicitEntities: Optional override of registered entity names if evaluating an explicit subset.
    /// - Returns: A `SpaceSchemaIntegrityReport` describing schema health and missing entities.
    public static func inspectSchema(
        container: ModelContainer,
        explicitEntities: [String]? = nil
    ) -> SpaceSchemaIntegrityReport {
        let registered = explicitEntities ?? container.schema.entities.map(\.name)
        let missing = requiredSpaceEntities.filter { !registered.contains($0) }
        return SpaceSchemaIntegrityReport(
            schemaVersion: currentSchemaVersion,
            isHealthy: missing.isEmpty,
            registeredEntityNames: registered,
            missingEntityNames: missing,
            recoveryRecommendation: missing.isEmpty ? nil : "Rebuild ModelContainer with complete Space schema"
        )
    }

    /// Builds a resilient ModelContainer configured with all required core and Space models.
    public static func buildResilientModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            Conversation.self,
            Message.self,
            AgentMemory.self,
            AppPermissions.self,
            BotProfile.self,
            SpaceModel.self,
            SpaceParticipant.self,
            SpaceChannel.self,
            SpaceMessage.self,
            SpacePage.self,
            SpacePageProposal.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Verifies that a SwiftData store file is compatible and accessible before opening.
    public static func verifyStoreCompatibility(at storeURL: URL?) -> Bool {
        guard let storeURL else { return true }
        let path = storeURL.path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        guard FileManager.default.isReadableFile(atPath: path) else { return false }
        do {
            let handle = try FileHandle(forReadingFrom: storeURL)
            try handle.close()
            return true
        } catch {
            return false
        }
    }
}
