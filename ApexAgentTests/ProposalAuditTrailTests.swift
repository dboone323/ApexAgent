// ProposalAuditTrailTests.swift
// Batch 124: Functional tests for SpaceDiffEngine, SpaceProposalAuditTrail,
// and SpaceProposalBatchReviewer.

import XCTest
import SwiftData
import CryptoKit
@testable import ApexAgentCore

@MainActor
final class ProposalAuditTrailTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        await SpaceProposalAuditTrail.shared.clear()
    }

    override func tearDown() async throws {
        await SpaceProposalAuditTrail.shared.clear()
        try await super.tearDown()
    }

    private func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([
            SpacePageProposal.self,
            SpaceModel.self,
            SpacePage.self,
            SpaceParticipant.self,
            SpaceChannel.self,
            SpaceMessage.self,
            BotProfile.self,
            AppPermissions.self,
            AgentMemory.self,
            Message.self,
            Conversation.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - 1. Diff Engine Tests

    func testDiffEngineUnchangedLines() {
        let content = "Line 1\nLine 2\nLine 3"
        let diff = SpaceDiffEngine.computeDiff(original: content, proposed: content)

        XCTAssertEqual(diff.addedCount, 0)
        XCTAssertEqual(diff.removedCount, 0)
        XCTAssertEqual(diff.unchangedCount, 3)
        XCTAssertTrue(diff.lines.allSatisfy { $0.kind == .unchanged })
    }

    func testDiffEngineAddsNewLine() {
        let original = "Line 1"
        let proposed = "Line 1\nLine 2"
        let diff = SpaceDiffEngine.computeDiff(original: original, proposed: proposed)

        XCTAssertEqual(diff.addedCount, 1)
        XCTAssertEqual(diff.removedCount, 0)
        let addedLines = diff.lines.filter { $0.kind == .added }
        XCTAssertEqual(addedLines.count, 1)
        XCTAssertEqual(addedLines.first?.text, "Line 2")
        XCTAssertEqual(addedLines.first?.lineNumber, 2)
    }

    func testDiffEngineRemovesLine() {
        let original = "Line 1\nLine 2"
        let proposed = "Line 1"
        let diff = SpaceDiffEngine.computeDiff(original: original, proposed: proposed)

        XCTAssertEqual(diff.addedCount, 0)
        XCTAssertEqual(diff.removedCount, 1)
        let removedLines = diff.lines.filter { $0.kind == .removed }
        XCTAssertEqual(removedLines.count, 1)
        XCTAssertEqual(removedLines.first?.text, "Line 2")
        XCTAssertEqual(removedLines.first?.lineNumber, 2)
    }

    func testDiffEngineMixedChanges() {
        let original = "Line 1\nOld Line 2\nLine 3"
        let proposed = "Line 1\nNew Line 2\nLine 3"
        let diff = SpaceDiffEngine.computeDiff(original: original, proposed: proposed)

        XCTAssertGreaterThanOrEqual(diff.addedCount, 1)
        XCTAssertGreaterThanOrEqual(diff.removedCount, 1)
    }

    func testDiffSummaryString() {
        let original = "A\nB"
        let proposed = "A\nC\nD"
        let diff = SpaceDiffEngine.computeDiff(original: original, proposed: proposed)

        XCTAssertEqual(diff.addedCount, 2)
        XCTAssertEqual(diff.removedCount, 1)
        XCTAssertEqual(diff.summary, "+2 -1 lines")
    }

    // MARK: - 2. Audit Trail Tests

    func testAuditTrailRecordsEntry() async {
        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Architecture",
            authorName: "Bot",
            summary: "Update architecture overview",
            originalContent: "Old text",
            proposedContent: "New text",
            state: .pending
        )
        let entry = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Bot"
        )
        let entries = await SpaceProposalAuditTrail.shared.entries(for: proposal.id)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.action, .staged)
        XCTAssertEqual(entry.action, .staged)
        XCTAssertEqual(entry.proposalId, proposal.id)
    }

    func testAuditTrailHashIsNotEmpty() async {
        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Roadmap",
            authorName: "Bot",
            summary: "Q4 goals",
            originalContent: "Draft",
            proposedContent: "Final roadmap",
            state: .pending
        )
        let entry = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Bot"
        )

        XCTAssertFalse(entry.stateHash.isEmpty)
        XCTAssertFalse(entry.proposedContentHash.isEmpty)
        XCTAssertEqual(entry.stateHash.count, 64)
        XCTAssertEqual(entry.proposedContentHash.count, 64)
    }

    func testAuditTrailHashIsDeterministicForSameContent() async {
        let content = "Exact proposed content for verification test."
        let expectedHash = SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Deterministic Test",
            authorName: "Tester",
            summary: "Hash test",
            originalContent: "Original",
            proposedContent: content,
            state: .pending
        )
        let entry = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Tester"
        )

        XCTAssertEqual(entry.proposedContentHash, expectedHash)
    }

    func testAuditTrailIntegrityVerificationPasses() async {
        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Spec",
            authorName: "Coder",
            summary: "Initial draft",
            originalContent: "Alpha",
            proposedContent: "Beta release spec",
            state: .pending
        )
        let entry = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Coder"
        )

        let verified = await SpaceProposalAuditTrail.shared.verifyIntegrity(of: entry, proposal: proposal)
        XCTAssertTrue(verified)
    }

    func testAuditTrailIntegrityVerificationFailsOnTamperedContent() async {
        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Security Audit",
            authorName: "Auditor",
            summary: "Security findings",
            originalContent: "Safe",
            proposedContent: "Verified secure",
            state: .pending
        )
        let entry = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Auditor"
        )

        proposal.proposedContent = "Tampered malicious payload"
        let verified = await SpaceProposalAuditTrail.shared.verifyIntegrity(of: entry, proposal: proposal)
        XCTAssertFalse(verified)
    }

    func testAuditTrailMultipleActionsForSameProposal() async {
        let proposal = SpacePageProposal(
            pageId: UUID(),
            pageTitle: "Feature Flag",
            authorName: "Bot",
            summary: "Enable flag",
            originalContent: "false",
            proposedContent: "true",
            state: .pending
        )
        _ = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .staged,
            actorName: "Bot"
        )
        _ = await SpaceProposalAuditTrail.shared.record(
            proposal: proposal,
            action: .approved,
            actorName: "Reviewer",
            feedback: "LGTM"
        )

        let entries = await SpaceProposalAuditTrail.shared.entries(for: proposal.id)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].action, .staged)
        XCTAssertEqual(entries[1].action, .approved)
        XCTAssertEqual(entries[1].feedback, "LGTM")
    }

    func testBatchApproveAllPendingProposals() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Batch Space")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        var allProposals: [SpacePageProposal] = []
        for i in 1...3 {
            let page = SpacePage(
                title: "Page \(i)",
                markdownBody: "Initial \(i)",
                lastEditedByName: "Admin"
            )
            page.space = space
            space.pages.append(page)
            context.insert(page)

            let proposal = SpacePageProposal(
                pageId: page.id,
                pageTitle: page.title,
                authorName: "Agent \(i)",
                summary: "Proposal \(i)",
                originalContent: page.markdownBody,
                proposedContent: "Approved Content \(i)",
                state: .pending
            )
            proposal.space = space
            space.proposals.append(proposal)
            context.insert(proposal)
            allProposals.append(proposal)
        }
        try context.save()

        let approvedCount = SpaceProposalBatchReviewer.approveAll(
            proposals: allProposals,
            spaceManager: spaceManager
        )

        XCTAssertEqual(approvedCount, 3)
        for p in allProposals {
            XCTAssertEqual(p.state, .approved)
        }
    }

    func testBatchDenyAllPendingProposals() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Batch Deny Space")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        var allProposals: [SpacePageProposal] = []
        for i in 1...3 {
            let proposal = SpacePageProposal(
                pageId: UUID(),
                pageTitle: "Page \(i)",
                authorName: "Agent \(i)",
                summary: "Proposal \(i)",
                originalContent: "Original \(i)",
                proposedContent: "Denied Content \(i)",
                state: .pending
            )
            proposal.space = space
            space.proposals.append(proposal)
            context.insert(proposal)
            allProposals.append(proposal)
        }
        try context.save()

        let deniedCount = SpaceProposalBatchReviewer.denyAll(
            proposals: allProposals,
            spaceManager: spaceManager,
            reason: "Bulk rejected"
        )

        XCTAssertEqual(deniedCount, 3)
        for p in allProposals {
            XCTAssertEqual(p.state, .denied)
            XCTAssertEqual(p.userFeedback, "Bulk rejected")
        }
    }

    func testBatchApproveSkipsNonPendingProposals() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Batch Skip Space")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        let page1 = SpacePage(title: "P1", markdownBody: "Body 1")
        page1.space = space
        space.pages.append(page1)
        context.insert(page1)

        let pendingProposal = SpacePageProposal(
            pageId: page1.id,
            pageTitle: page1.title,
            authorName: "Agent",
            summary: "Pending Update",
            originalContent: "Body 1",
            proposedContent: "New Body 1",
            state: .pending
        )
        pendingProposal.space = space
        space.proposals.append(pendingProposal)
        context.insert(pendingProposal)

        let page2 = SpacePage(title: "P2", markdownBody: "Body 2")
        page2.space = space
        space.pages.append(page2)
        context.insert(page2)

        let alreadyApprovedProposal = SpacePageProposal(
            pageId: page2.id,
            pageTitle: page2.title,
            authorName: "Agent",
            summary: "Already Done",
            originalContent: "Body 2",
            proposedContent: "Already Approved Body",
            state: .approved
        )
        alreadyApprovedProposal.space = space
        space.proposals.append(alreadyApprovedProposal)
        context.insert(alreadyApprovedProposal)

        try context.save()

        let approvedCount = SpaceProposalBatchReviewer.approveAll(
            proposals: [pendingProposal, alreadyApprovedProposal],
            spaceManager: spaceManager
        )

        XCTAssertEqual(approvedCount, 1)
        XCTAssertEqual(pendingProposal.state, .approved)
        XCTAssertEqual(alreadyApprovedProposal.state, .approved)
    }

    func testAuditTrailClear() async {
        for i in 1...3 {
            let proposal = SpacePageProposal(
                pageId: UUID(),
                pageTitle: "Clear Test \(i)",
                authorName: "Tester",
                summary: "Clear summary \(i)",
                originalContent: "A",
                proposedContent: "B \(i)",
                state: .pending
            )
            _ = await SpaceProposalAuditTrail.shared.record(
                proposal: proposal,
                action: .staged,
                actorName: "Tester"
            )
        }

        let beforeClear = await SpaceProposalAuditTrail.shared.allEntries()
        XCTAssertEqual(beforeClear.count, 3)

        await SpaceProposalAuditTrail.shared.clear()
        let afterClear = await SpaceProposalAuditTrail.shared.allEntries()
        XCTAssertTrue(afterClear.isEmpty)
    }
}
