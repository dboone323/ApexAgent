import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Shared Memory Blocks Tests (Issue #84)")
struct SharedMemoryBlocksTests {

    private func createTempStorage(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("apexagent-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. Shared Reading Across Agents in Same Space

    @Test("Two agents in the same Space see the same block content")
    @MainActor
    func testTwoAgentsInSameSpaceReadSameBlockContent() throws {
        let storage = try createTempStorage(prefix: "test-shared-read")
        defer { try? FileManager.default.removeItem(at: storage) }

        let service = SharedMemoryBlockService(storageDirectory: storage)
        let spaceId = "space-alpha"
        let blockId = "project_roadmap"
        let payload = "Milestone 1: Complete core shared memory architecture."

        // Agent A writes
        let writeResult = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: payload,
            writerId: "agent_architect_A"
        )

        guard case .success(let blockA) = writeResult else {
            Issue.record("Expected write to succeed, got: \(writeResult)")
            return
        }

        #expect(blockA.id == blockId)
        #expect(blockA.spaceId == spaceId)
        #expect(blockA.content == payload)
        #expect(blockA.version == 1)
        #expect(blockA.writerId == "agent_architect_A")

        // Agent B in the same Space reads the block
        let readByAgentB = service.readBlock(spaceId: spaceId, blockId: blockId)
        let blockB = try #require(readByAgentB)

        #expect(blockB.id == blockA.id)
        #expect(blockB.content == blockA.content)
        #expect(blockB.version == blockA.version)
        #expect(blockB.writerId == blockA.writerId)
    }

    // MARK: - 2. Write Visibility Across Agents

    @Test("A write by one agent is immediately visible to another agent in the same Space")
    @MainActor
    func testWriteByOneAgentIsImmediatelyVisibleToAnotherAgent() throws {
        let storage = try createTempStorage(prefix: "test-write-visibility")
        defer { try? FileManager.default.removeItem(at: storage) }

        let service = SharedMemoryBlockService(storageDirectory: storage)
        let spaceId = "space-alpha"
        let blockId = "triage_status"

        // Initial write by Agent A
        _ = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: "Status: Investigating",
            writerId: "agent_A"
        )

        // Agent B reads initial state
        let initialRead = try #require(service.readBlock(spaceId: spaceId, blockId: blockId))
        #expect(initialRead.version == 1)
        #expect(initialRead.content == "Status: Investigating")

        // Agent B updates the block
        let updateResult = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: "Status: Root cause identified in memory layer",
            writerId: "agent_B",
            expectedVersion: 1
        )

        guard case .success(let updatedBlock) = updateResult else {
            Issue.record("Expected update write to succeed, got: \(updateResult)")
            return
        }

        #expect(updatedBlock.version == 2)
        #expect(updatedBlock.writerId == "agent_B")

        // Agent A reads the updated state
        let readByAgentA = try #require(service.readBlock(spaceId: spaceId, blockId: blockId))
        #expect(readByAgentA.version == 2)
        #expect(readByAgentA.writerId == "agent_B")
        #expect(readByAgentA.content == "Status: Root cause identified in memory layer")
    }

    // MARK: - 3. Conflict Handling: Stale / Concurrent Writes Preserve Both Values

    @Test("A conflicting concurrent write produces a conflict record with both values preserved")
    @MainActor
    func testConflictingConcurrentWriteProducesConflictRecordWithBothValuesPreserved() throws {
        let storage = try createTempStorage(prefix: "test-conflict-handling")
        defer { try? FileManager.default.removeItem(at: storage) }

        let service = SharedMemoryBlockService(storageDirectory: storage)
        let spaceId = "space-alpha"
        let blockId = "architecture_decision"

        // Base revision
        let baseContent = "ADR 001: Initial baseline draft."
        _ = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: baseContent,
            writerId: "agent_A"
        )

        // Agent B advances to revision 2
        let winningContent = "ADR 001: Adopt event-driven synchronization."
        let bResult = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: winningContent,
            writerId: "agent_B",
            expectedVersion: 1
        )
        #expect(bResult.isSuccess)

        // Agent C attempts to write based on stale revision 1
        let conflictingContent = "ADR 001: Adopt polling synchronization."
        let cResult = service.writeBlock(
            spaceId: spaceId,
            blockId: blockId,
            content: conflictingContent,
            writerId: "agent_C",
            expectedVersion: 1
        )

        // Must produce a conflict result without throwing or silently losing data
        guard case .conflict(let conflict, let current) = cResult else {
            Issue.record("Expected write to produce a conflict result, got: \(cResult)")
            return
        }

        #expect(current.version == 2)
        #expect(current.content == winningContent)

        // Conflict record assertions: verify zero data loss
        #expect(conflict.blockId == blockId)
        #expect(conflict.spaceId == spaceId)
        #expect(conflict.baseVersion == 1)
        #expect(conflict.currentVersion == 2)
        #expect(conflict.winningWriterId == "agent_B")
        #expect(conflict.winningContent == winningContent)
        #expect(conflict.conflictingWriterId == "agent_C")
        #expect(conflict.conflictingContent == conflictingContent)
        #expect(conflict.reason.contains("agent_C"))

        // Audit log query
        let conflicts = service.getConflicts(spaceId: spaceId, blockId: blockId)
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.conflictingContent == conflictingContent)

        // Conflict resolution preserves audit record while applying chosen consensus
        let resolved = service.resolveConflict(
            conflictId: conflict.id,
            spaceId: spaceId,
            chosenContent: "ADR 001: Hybrid event + polling consensus.",
            resolverId: "agent_lead"
        )
        let resolvedBlock = try #require(resolved)
        #expect(resolvedBlock.version == 3)
        #expect(resolvedBlock.content == "ADR 001: Hybrid event + polling consensus.")
        #expect(service.getConflicts(spaceId: spaceId, blockId: blockId).count == 1)
    }

    // MARK: - 4. Space Scoping Isolation

    @Test("Blocks are scoped per Space (another Space cannot see them)")
    @MainActor
    func testBlocksAreScopedPerSpace() throws {
        let storage = try createTempStorage(prefix: "test-space-scoping")
        defer { try? FileManager.default.removeItem(at: storage) }

        let service = SharedMemoryBlockService(storageDirectory: storage)
        let spaceAlpha = "space-alpha"
        let spaceBeta = "space-beta"
        let blockId = "confidential_spec"

        _ = service.writeBlock(
            spaceId: spaceAlpha,
            blockId: blockId,
            content: "Confidential Alpha Details",
            writerId: "agent_alpha"
        )

        // Space Beta must not see Space Alpha's block
        let betaRead = service.readBlock(spaceId: spaceBeta, blockId: blockId)
        #expect(betaRead == nil)

        let betaList = service.listBlocks(spaceId: spaceBeta)
        #expect(betaList.isEmpty)

        // Space Beta can have its own block with the same ID independently
        _ = service.writeBlock(
            spaceId: spaceBeta,
            blockId: blockId,
            content: "Space Beta Distinct Details",
            writerId: "agent_beta"
        )

        let readAlpha = try #require(service.readBlock(spaceId: spaceAlpha, blockId: blockId))
        let readBeta = try #require(service.readBlock(spaceId: spaceBeta, blockId: blockId))

        #expect(readAlpha.content == "Confidential Alpha Details")
        #expect(readBeta.content == "Space Beta Distinct Details")
    }

    // MARK: - 5. Persistence Across Fresh Service Instances

    @Test("A block persists across a fresh service instance")
    @MainActor
    func testBlocksAndConflictsPersistAcrossFreshServiceInstances() throws {
        let storage = try createTempStorage(prefix: "test-persistence")
        defer { try? FileManager.default.removeItem(at: storage) }

        let spaceId = "space-persistent"
        let blockId = "persistent_notes"

        // Instance 1 creates and mutates state
        do {
            let service1 = SharedMemoryBlockService(storageDirectory: storage)
            _ = service1.writeBlock(
                spaceId: spaceId,
                blockId: blockId,
                content: "Rev 1 Content",
                writerId: "agent_init"
            )

            _ = service1.writeBlock(
                spaceId: spaceId,
                blockId: blockId,
                content: "Rev 2 Content",
                writerId: "agent_upd",
                expectedVersion: 1
            )

            // Trigger a conflict to persist conflict history as well
            _ = service1.writeBlock(
                spaceId: spaceId,
                blockId: blockId,
                content: "Stale Rev Content",
                writerId: "agent_stale",
                expectedVersion: 1
            )
        }

        // Instance 2 connects to the same storage folder
        do {
            let service2 = SharedMemoryBlockService(storageDirectory: storage)

            let restoredBlock = try #require(service2.readBlock(spaceId: spaceId, blockId: blockId))
            #expect(restoredBlock.version == 2)
            #expect(restoredBlock.content == "Rev 2 Content")
            #expect(restoredBlock.writerId == "agent_upd")

            let restoredConflicts = service2.getConflicts(spaceId: spaceId, blockId: blockId)
            #expect(restoredConflicts.count == 1)
            #expect(restoredConflicts.first?.conflictingWriterId == "agent_stale")
            #expect(restoredConflicts.first?.conflictingContent == "Stale Rev Content")
        }

        // Verify Live Verifier check matrix passes cleanly
        let liveResult = SharedMemoryBlocksLiveVerifier.runVerification(writeLogTo: "runs/issue84/live-verify.log")
        #expect(liveResult.passed == true)
    }
}
