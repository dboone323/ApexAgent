// SpaceThreadDispatcherTests.swift
// Batch 127: Functional tests for SpaceThreadDispatcher autonomous thread
// investigation coordination and root summary engine.

import XCTest
import SwiftData
@testable import ApexAgentCore

@MainActor
final class SpaceThreadDispatcherTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await SpaceThreadDispatcher.shared.resetAll()
    }

    override func tearDown() async throws {
        await SpaceThreadDispatcher.shared.resetAll()
        try await super.tearDown()
    }

    // MARK: - 1. Start Investigation

    func testStartInvestigationCreatesActiveRecord() async {
        let channelId = UUID()
        let rootMessageId = UUID()
        let bot1 = UUID()
        let bot2 = UUID()
        let prompt = "Investigate performance bottleneck in vector similarity indexing"

        let metadata = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelId,
            rootMessageId: rootMessageId,
            prompt: prompt,
            assignedBotIds: [bot1, bot2]
        )

        XCTAssertEqual(metadata.channelId, channelId)
        XCTAssertEqual(metadata.threadParentId, rootMessageId)
        XCTAssertEqual(metadata.taskPrompt, prompt)
        XCTAssertEqual(metadata.assignedBotIds, [bot1, bot2])
        XCTAssertEqual(metadata.state, .active)
        XCTAssertEqual(metadata.replyCount, 0)
        XCTAssertNil(metadata.completedAt)
        XCTAssertNil(metadata.summaryText)

        let fetched = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: rootMessageId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.channelId, channelId)
        XCTAssertEqual(fetched?.state, .active)
        XCTAssertEqual(fetched?.replyCount, 0)
    }

    // MARK: - 2. Record Reply

    func testRecordReplyIncrementsReplyCount() async throws {
        let channelId = UUID()
        let rootMessageId = UUID()
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelId,
            rootMessageId: rootMessageId,
            prompt: "Diagnose gateway WebSocket disconnection",
            assignedBotIds: [UUID()]
        )

        let reply1Id = UUID()
        try await SpaceThreadDispatcher.shared.recordReply(
            threadParentId: rootMessageId,
            replyMessageId: reply1Id
        )

        var current = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: rootMessageId)
        XCTAssertEqual(current?.replyCount, 1)

        let reply2Id = UUID()
        let reply3Id = UUID()
        try await SpaceThreadDispatcher.shared.recordReply(
            threadParentId: rootMessageId,
            replyMessageId: reply2Id
        )
        try await SpaceThreadDispatcher.shared.recordReply(
            threadParentId: rootMessageId,
            replyMessageId: reply3Id
        )

        current = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: rootMessageId)
        XCTAssertEqual(current?.replyCount, 3)

        let replies = await SpaceThreadDispatcher.shared.replies(for: rootMessageId)
        XCTAssertEqual(replies, [reply1Id, reply2Id, reply3Id])
    }

    // MARK: - 3. Conclude Investigation

    func testConcludeInvestigationUpdatesStateAndSummary() async throws {
        let channelId = UUID()
        let rootMessageId = UUID()
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelId,
            rootMessageId: rootMessageId,
            prompt: "Resolve race condition in actor message mailbox",
            assignedBotIds: [UUID(), UUID()]
        )

        let replyId = UUID()
        try await SpaceThreadDispatcher.shared.recordReply(threadParentId: rootMessageId, replyMessageId: replyId)

        let summaryText = "Identified re-entrancy issue. Added serial task queue before awaiting state mutation."
        let concluded = try await SpaceThreadDispatcher.shared.concludeInvestigation(
            threadParentId: rootMessageId,
            summary: summaryText
        )

        XCTAssertEqual(concluded.state, .concluded)
        XCTAssertEqual(concluded.summaryText, summaryText)
        XCTAssertNotNil(concluded.completedAt)
        XCTAssertEqual(concluded.replyCount, 1)

        let fetched = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: rootMessageId)
        XCTAssertEqual(fetched?.state, .concluded)
        XCTAssertEqual(fetched?.summaryText, summaryText)
        XCTAssertNotNil(fetched?.completedAt)
    }

    // MARK: - 4. Mark Stalled

    func testMarkStalledUpdatesState() async throws {
        let channelId = UUID()
        let rootMessageId = UUID()
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelId,
            rootMessageId: rootMessageId,
            prompt: "Inspect network timeout with upstream Ollama instance",
            assignedBotIds: [UUID()]
        )

        try await SpaceThreadDispatcher.shared.markStalled(threadParentId: rootMessageId)

        let fetched = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: rootMessageId)
        XCTAssertEqual(fetched?.state, .stalled)
    }

    // MARK: - 5. Active Investigations Filter

    func testActiveInvestigationsFiltersConcluded() async throws {
        let channelA = UUID()
        let channelB = UUID()

        let rootA1 = UUID()
        let rootA2 = UUID()
        let rootB1 = UUID()

        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelA,
            rootMessageId: rootA1,
            prompt: "Task A1",
            assignedBotIds: [UUID()]
        )
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelA,
            rootMessageId: rootA2,
            prompt: "Task A2",
            assignedBotIds: [UUID()]
        )
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelB,
            rootMessageId: rootB1,
            prompt: "Task B1",
            assignedBotIds: [UUID()]
        )

        // Conclude rootA1
        _ = try await SpaceThreadDispatcher.shared.concludeInvestigation(
            threadParentId: rootA1,
            summary: "Task A1 concluded."
        )

        let activeA = await SpaceThreadDispatcher.shared.activeInvestigations(for: channelA)
        XCTAssertEqual(activeA.count, 1)
        XCTAssertEqual(activeA.first?.threadParentId, rootA2)

        let activeB = await SpaceThreadDispatcher.shared.activeInvestigations(for: channelB)
        XCTAssertEqual(activeB.count, 1)
        XCTAssertEqual(activeB.first?.threadParentId, rootB1)
    }

    // MARK: - 6. Format Summary For Channel Root

    func testFormatSummaryForChannelRootProducesExpectedMarkdown() async throws {
        let channelId = UUID()
        let rootMessageId = UUID()
        let bot1 = UUID()
        let bot2 = UUID()

        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channelId,
            rootMessageId: rootMessageId,
            prompt: "Analyze token usage in agent swarm",
            assignedBotIds: [bot1, bot2]
        )

        try await SpaceThreadDispatcher.shared.recordReply(threadParentId: rootMessageId, replyMessageId: UUID())
        try await SpaceThreadDispatcher.shared.recordReply(threadParentId: rootMessageId, replyMessageId: UUID())
        try await SpaceThreadDispatcher.shared.recordReply(threadParentId: rootMessageId, replyMessageId: UUID())

        let summaryText = "Token consumption reduced by 40% using semantic caching and context compaction."
        let concluded = try await SpaceThreadDispatcher.shared.concludeInvestigation(
            threadParentId: rootMessageId,
            summary: summaryText
        )

        let markdown = await SpaceThreadDispatcher.shared.formatSummaryForChannelRoot(investigation: concluded)

        let expectedLines = [
            "🧵 **Thread Investigation Concluded**",
            "**Task:** Analyze token usage in agent swarm",
            "**Participants:** 2 agent(s) · 3 replies",
            "---",
            summaryText
        ]
        let expectedMarkdown = expectedLines.joined(separator: "\n")

        XCTAssertEqual(markdown, expectedMarkdown)

        // Test with nil summary text fallback
        let unsummarizedMetadata = ThreadInvestigationMetadata(
            threadParentId: UUID(),
            channelId: channelId,
            taskPrompt: "Empty fallback prompt",
            assignedBotIds: [bot1],
            summaryText: nil,
            replyCount: 0
        )
        let fallbackMarkdown = await SpaceThreadDispatcher.shared.formatSummaryForChannelRoot(investigation: unsummarizedMetadata)
        XCTAssertTrue(fallbackMarkdown.contains("No summary provided."))
    }

    // MARK: - 7. Record Reply Throws For Non-Existent Thread

    func testRecordReplyThrowsForNonExistentThread() async {
        let nonExistentId = UUID()
        let replyId = UUID()

        do {
            try await SpaceThreadDispatcher.shared.recordReply(
                threadParentId: nonExistentId,
                replyMessageId: replyId
            )
            XCTFail("recordReply should throw for non-existent thread")
        } catch let nsError as NSError {
            XCTAssertEqual(nsError.domain, "SpaceThreadDispatcher")
            XCTAssertEqual(nsError.code, 404)
        }

        do {
            _ = try await SpaceThreadDispatcher.shared.concludeInvestigation(
                threadParentId: nonExistentId,
                summary: "Invalid thread conclusion"
            )
            XCTFail("concludeInvestigation should throw for non-existent thread")
        } catch let nsError as NSError {
            XCTAssertEqual(nsError.domain, "SpaceThreadDispatcher")
            XCTAssertEqual(nsError.code, 404)
        }

        do {
            try await SpaceThreadDispatcher.shared.markStalled(threadParentId: nonExistentId)
            XCTFail("markStalled should throw for non-existent thread")
        } catch let nsError as NSError {
            XCTAssertEqual(nsError.domain, "SpaceThreadDispatcher")
            XCTAssertEqual(nsError.code, 404)
        }
    }

    // MARK: - 8. Reset All Clears State

    func testResetAllClearsAllState() async {
        let root1 = UUID()
        let root2 = UUID()

        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: UUID(),
            rootMessageId: root1,
            prompt: "Task 1",
            assignedBotIds: [UUID()]
        )
        _ = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: UUID(),
            rootMessageId: root2,
            prompt: "Task 2",
            assignedBotIds: [UUID()]
        )

        let before = await SpaceThreadDispatcher.shared.allInvestigations()
        XCTAssertEqual(before.count, 2)

        await SpaceThreadDispatcher.shared.resetAll()

        let after = await SpaceThreadDispatcher.shared.allInvestigations()
        XCTAssertTrue(after.isEmpty)
        let fetched1 = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: root1)
        let fetched2 = await SpaceThreadDispatcher.shared.getInvestigation(threadParentId: root2)
        XCTAssertNil(fetched1)
        XCTAssertNil(fetched2)
    }

    // MARK: - 9. Integration with SwiftData Space Models

    func testIntegrationWithSwiftDataSpaceModels() async throws {
        let schema = Schema([
            SpaceModel.self,
            SpaceChannel.self,
            SpaceMessage.self,
            SpaceParticipant.self,
            SpacePage.self,
            SpacePageProposal.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = container.mainContext

        let space = SpaceModel(name: "Autonomous Architecture Space")
        context.insert(space)

        let channel = SpaceChannel(name: "investigations", topic: "Multi-agent deep dives")
        channel.space = space
        space.channels.append(channel)
        context.insert(channel)

        let rootMessage = SpaceMessage(
            senderParticipantId: UUID(),
            senderName: "ChiefOfStaff",
            senderHandle: "chief",
            senderKind: .bot,
            content: "Dispatched sub-task: investigate database sync stall during snapshot export."
        )
        rootMessage.channel = channel
        channel.messages.append(rootMessage)
        context.insert(rootMessage)

        try context.save()

        let bot1 = UUID()
        let bot2 = UUID()

        let investigation = await SpaceThreadDispatcher.shared.startInvestigation(
            channelId: channel.id,
            rootMessageId: rootMessage.id,
            prompt: "Investigate database sync stall during snapshot export",
            assignedBotIds: [bot1, bot2]
        )
        XCTAssertEqual(investigation.state, .active)
        XCTAssertEqual(investigation.replyCount, 0)

        // Add 2 child SpaceMessage instances with threadParentId: rootMessage.id to the channel
        let reply1 = SpaceMessage(
            senderParticipantId: bot1,
            senderName: "DbAnalyst",
            senderHandle: "db-analyst",
            senderKind: .bot,
            content: "Found sqlite WAL lock conflict during concurrent snapshot read.",
            threadParentId: rootMessage.id
        )
        reply1.channel = channel
        channel.messages.append(reply1)
        context.insert(reply1)
        try await SpaceThreadDispatcher.shared.recordReply(
            threadParentId: rootMessage.id,
            replyMessageId: reply1.id
        )

        let reply2 = SpaceMessage(
            senderParticipantId: bot2,
            senderName: "LockAuditor",
            senderHandle: "lock-auditor",
            senderKind: .bot,
            content: "Applied read-only replica connection for snapshotting to prevent lock.",
            threadParentId: rootMessage.id
        )
        reply2.channel = channel
        channel.messages.append(reply2)
        context.insert(reply2)
        try await SpaceThreadDispatcher.shared.recordReply(
            threadParentId: rootMessage.id,
            replyMessageId: reply2.id
        )

        try context.save()

        // Verifies channel.threadReplies(for: rootMessage.id).count == 2
        let threadReplies = channel.threadReplies(for: rootMessage.id)
        XCTAssertEqual(threadReplies.count, 2)
        XCTAssertEqual(threadReplies.map(\.id), [reply1.id, reply2.id])

        // Concludes investigation with dispatcher, verifies summary format
        let summaryText = "Root cause was WAL contention on main DB handle. Fixed with read-only connection pool."
        let concluded = try await SpaceThreadDispatcher.shared.concludeInvestigation(
            threadParentId: rootMessage.id,
            summary: summaryText
        )
        XCTAssertEqual(concluded.state, .concluded)
        XCTAssertEqual(concluded.replyCount, 2)

        let summaryMarkdown = await SpaceThreadDispatcher.shared.formatSummaryForChannelRoot(investigation: concluded)
        XCTAssertTrue(summaryMarkdown.contains("🧵 **Thread Investigation Concluded**"))
        XCTAssertTrue(summaryMarkdown.contains("**Task:** Investigate database sync stall during snapshot export"))
        XCTAssertTrue(summaryMarkdown.contains("**Participants:** 2 agent(s) · 2 replies"))
        XCTAssertTrue(summaryMarkdown.contains("Root cause was WAL contention on main DB handle. Fixed with read-only connection pool."))
    }
}
