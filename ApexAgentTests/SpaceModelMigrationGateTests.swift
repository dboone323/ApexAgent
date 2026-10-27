// SpaceModelMigrationGateTests.swift
// Batch 129: Tests for SpaceModelMigrationGate schema inspector and resilient container builder.

import XCTest
import SwiftData
@testable import ApexAgentCore

@MainActor
final class SpaceModelMigrationGateTests: XCTestCase {

    func testInspectCompleteSchemaReturnsHealthyReport() throws {
        let container = try SpaceModelMigrationGate.buildResilientModelContainer(inMemory: true)
        let report = SpaceModelMigrationGate.inspectSchema(container: container)

        XCTAssertTrue(report.isHealthy)
        XCTAssertTrue(report.missingEntityNames.isEmpty)
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertNil(report.recoveryRecommendation)
    }

    func testInspectIncompleteSchemaFlagsMissingEntities() throws {
        // Build a container with partial schema lacking Space entities
        let schema = Schema([Conversation.self, Message.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let report = SpaceModelMigrationGate.inspectSchema(container: container)

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.missingEntityNames.contains("SpacePageProposal"))
        XCTAssertNotNil(report.recoveryRecommendation)
    }

    func testInspectExplicitPartialSchemaFlagsMissingEntities() throws {
        let schema = Schema([SpaceModel.self, SpacePage.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let report = SpaceModelMigrationGate.inspectSchema(
            container: container,
            explicitEntities: ["SpaceModel", "SpacePage"]
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.missingEntityNames.contains("SpacePageProposal"))
        XCTAssertNotNil(report.recoveryRecommendation)
    }

    func testBuildResilientContainerContainsAllEntities() throws {
        let container = try SpaceModelMigrationGate.buildResilientModelContainer(inMemory: true)
        let entityNames = container.schema.entities.map(\.name)
        for required in SpaceModelMigrationGate.requiredSpaceEntities {
            XCTAssertTrue(entityNames.contains(required), "Missing required space entity: \(required)")
        }
    }

    func testVerifyStoreCompatibilityWithNilURLReturnsTrue() {
        XCTAssertTrue(SpaceModelMigrationGate.verifyStoreCompatibility(at: nil))
    }

    func testVerifyStoreCompatibilityWithNonExistentURLReturnsTrue() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        XCTAssertTrue(SpaceModelMigrationGate.verifyStoreCompatibility(at: tempURL))
    }

    func testVerifyStoreCompatibilityWithExistingFileReturnsTrue() throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        try "test data".write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        XCTAssertTrue(SpaceModelMigrationGate.verifyStoreCompatibility(at: tempURL))
    }

    func testReportCodableRoundTrip() throws {
        let report = SpaceSchemaIntegrityReport(
            schemaVersion: 2,
            isHealthy: false,
            registeredEntityNames: ["SpaceModel"],
            missingEntityNames: ["SpacePageProposal"],
            recoveryRecommendation: "Rebuild ModelContainer with complete Space schema"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(report)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(SpaceSchemaIntegrityReport.self, from: data)

        XCTAssertEqual(report, decoded)
    }

    func testSpaceModelAndProposalSendableCompliance() {
        let space = SpaceModel(
            name: "Compliance Space",
            summary: "Verifying macro Sendable synthesis without unchecked annotation"
        )
        XCTAssertEqual(space.name, "Compliance Space")

        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Architecture Proposal",
            summary: "Hardening test",
            originalContent: "# Old",
            proposedContent: "# New"
        )
        XCTAssertEqual(proposal.pageTitle, "Architecture Proposal")
        XCTAssertEqual(proposal.proposedContent, "# New")
    }
}
