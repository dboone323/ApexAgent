import XCTest
import SwiftData
@testable import ApexAgentCore

@MainActor
final class OpenDotsTests: XCTestCase {

    private func makeInMemoryContainer() throws -> ModelContainer {
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
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Dot Sandbox File Operations & Security

    func testDotSandboxCreationAndFileOperations() throws {
        let dotId = UUID()
        let manager = DotSandboxManager.shared

        let rootURL = try manager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: rootURL.appendingPathComponent("workspace").path))
        XCTAssertTrue(fm.fileExists(atPath: rootURL.appendingPathComponent("notes").path))
        XCTAssertTrue(fm.fileExists(atPath: rootURL.appendingPathComponent("scratch").path))
        XCTAssertTrue(fm.fileExists(atPath: rootURL.appendingPathComponent("outputs").path))

        let testContent = "# OpenDots Architecture\nMulti-agent collaboration verified."
        try manager.writeSandboxFile(for: dotId, relativePath: "notes/opendots.md", content: testContent)

        let readBack = try manager.readSandboxFile(for: dotId, relativePath: "notes/opendots.md")
        XCTAssertEqual(readBack, testContent)

        let files = try manager.listSandboxFiles(for: dotId, relativePath: "notes")
        XCTAssertTrue(files.contains("opendots.md"))
    }

    func testDotSandboxDirectoryTraversalRejection() throws {
        let dotId = UUID()
        let manager = DotSandboxManager.shared
        _ = try manager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: manager.sandboxURL(for: dotId).deletingLastPathComponent())
        }

        // Test ../ path escaping attempts are rejected with 403
        let escapedPath = "../../../../../etc/passwd"
        XCTAssertThrowsError(try manager.resolvePath(for: dotId, relativePath: escapedPath)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DotSandboxManager")
            XCTAssertEqual(nsError.code, 403)
        }

        let evilResolved = "workspace/../../outside.txt"
        XCTAssertThrowsError(try manager.resolvePath(for: dotId, relativePath: evilResolved)) { error in
            let nsError = error as NSError
            XCTAssertEqual(nsError.domain, "DotSandboxManager")
            XCTAssertEqual(nsError.code, 403)
        }
    }

    func testDotSandboxCommandExecution() async throws {
        let dotId = UUID()
        let manager = DotSandboxManager.shared
        let rootURL = try manager.ensureSandbox(for: dotId)
        defer {
            try? FileManager.default.removeItem(at: rootURL.deletingLastPathComponent())
        }

        let result = try await manager.executeSandboxedCommand(
            for: dotId,
            command: "echo 'opendots execution test'"
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.output.contains("opendots execution test"))
    }

    // MARK: - Space Page Proposal Lifecycle (Approve, Deny, Change)

    func testSpacePageProposalApprovalLifecycle() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        botManager.modelContext = context

        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Test OpenSpace")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        let page = SpacePage(
            title: "Roadmap",
            markdownBody: "Initial Roadmap Content",
            lastEditedByName: "Human"
        )
        page.space = space
        space.pages.append(page)
        context.insert(page)
        try context.save()

        let proposal = SpacePageProposal(
            pageId: page.id,
            pageTitle: page.title,
            authorName: "Dot-Coder",
            summary: "Update Q4 roadmap goals",
            originalContent: page.markdownBody,
            proposedContent: "Updated Q4 Roadmap with OpenDots features",
            state: .pending
        )
        proposal.space = space
        space.proposals.append(proposal)
        context.insert(proposal)
        try context.save()

        XCTAssertEqual(space.pendingProposals.count, 1)

        // Approve proposal
        spaceManager.approveProposal(proposal, editorName: "Lead Human")

        XCTAssertEqual(proposal.state, .approved)
        XCTAssertNotNil(proposal.reviewedAt)
        XCTAssertEqual(page.markdownBody, "Updated Q4 Roadmap with OpenDots features")
        XCTAssertTrue(page.lastEditedByName.contains("Approved by Lead Human"))
        XCTAssertEqual(space.pendingProposals.count, 0)
    }

    func testSpacePageProposalDenialLifecycle() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Test OpenSpace")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        let page = SpacePage(
            title: "Architecture",
            markdownBody: "Current Clean Architecture",
            lastEditedByName: "Human"
        )
        page.space = space
        space.pages.append(page)
        context.insert(page)
        try context.save()

        let proposal = SpacePageProposal(
            pageId: page.id,
            pageTitle: page.title,
            authorName: "Rogue-Dot",
            summary: "Rewrite everything",
            originalContent: page.markdownBody,
            proposedContent: "Unapproved rewrite",
            state: .pending
        )
        proposal.space = space
        space.proposals.append(proposal)
        context.insert(proposal)
        try context.save()

        // Deny proposal
        spaceManager.denyProposal(proposal, reason: "Does not meet safety guidelines")

        XCTAssertEqual(proposal.state, .denied)
        XCTAssertEqual(proposal.userFeedback, "Does not meet safety guidelines")
        XCTAssertEqual(page.markdownBody, "Current Clean Architecture")
        XCTAssertEqual(space.pendingProposals.count, 0)
    }

    func testSpacePageProposalModifyAndApproveLifecycle() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        let spaceManager = SpaceManager(orchestrator: orchestrator, botManager: botManager)
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Test OpenSpace")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        let page = SpacePage(
            title: "Guidelines",
            markdownBody: "v1 Guidelines",
            lastEditedByName: "Human"
        )
        page.space = space
        space.pages.append(page)
        context.insert(page)
        try context.save()

        let proposal = SpacePageProposal(
            pageId: page.id,
            pageTitle: page.title,
            authorName: "Dot-Writer",
            summary: "Proposed v2 Guidelines",
            originalContent: page.markdownBody,
            proposedContent: "Draft v2 Guidelines with typos",
            state: .pending
        )
        proposal.space = space
        space.proposals.append(proposal)
        context.insert(proposal)
        try context.save()

        // Modify and Approve
        let humanRefined = "Draft v2 Guidelines (Clean & Typos Fixed)"
        spaceManager.modifyAndApproveProposal(proposal, modifiedContent: humanRefined, editorName: "Lead")

        XCTAssertEqual(proposal.state, .modified)
        XCTAssertEqual(proposal.proposedContent, humanRefined)
        XCTAssertEqual(page.markdownBody, humanRefined)
        XCTAssertTrue(page.lastEditedByName.contains("Lead"))
        XCTAssertTrue(page.lastEditedByName.contains("Modified Dot-Writer's draft"))
        XCTAssertEqual(space.pendingProposals.count, 0)
    }

    // MARK: - Space Tools Verification

    func testSpacePageToolsReadAndWriteStaging() async throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let orchestrator = AgentOrchestrator()
        let spaceManager = SpaceManager.shared
        spaceManager.modelContext = context

        let space = SpaceModel(name: "Collaborative OpenSpace")
        context.insert(space)
        spaceManager.spaces = [space]
        spaceManager.selectSpace(space)

        let page = SpacePage(
            title: "Overview",
            markdownBody: "ApexAgent collaborative spaces overview.",
            lastEditedByName: "Admin"
        )
        page.space = space
        space.pages.append(page)
        context.insert(page)
        try context.save()

        // 1. SpaceReadPageTool
        let readTool = SpaceReadPageTool(orchestrator: orchestrator)
        let readArgs = SpaceReadPageTool.Arguments(pageTitleOrId: "Overview")
        let readResult = try await readTool.call(arguments: readArgs)
        XCTAssertTrue(readResult.contains("ApexAgent collaborative spaces overview."))

        // 2. SpaceWritePageTool
        let writeTool = SpaceWritePageTool(orchestrator: orchestrator)
        let writeArgs = SpaceWritePageTool.Arguments(
            pageTitleOrId: "Overview",
            content: "Updated overview with OpenDots integration details.",
            summary: "Added OpenDots support"
        )
        let writeResult = try await writeTool.call(arguments: writeArgs)
        XCTAssertTrue(writeResult.contains("Staged proposal"))

        // Verify proposal staged in space
        XCTAssertEqual(space.pendingProposals.count, 1)
        let staged = try XCTUnwrap(space.pendingProposals.first)
        XCTAssertEqual(staged.proposedContent, "Updated overview with OpenDots integration details.")
        XCTAssertEqual(staged.state, .pending)

        // 3. SpaceProposeDiffTool
        let diffTool = SpaceProposeDiffTool(orchestrator: orchestrator)
        let diffArgs = SpaceProposeDiffTool.Arguments(
            pageTitleOrId: "Overview",
            searchContent: "collaborative spaces",
            replaceContent: "supercharged collaborative spaces",
            summary: "Enhanced wording"
        )
        let diffResult = try await diffTool.call(arguments: diffArgs)
        XCTAssertTrue(diffResult.contains("Staged diff proposal"))
        XCTAssertEqual(space.pendingProposals.count, 2)
    }

    // MARK: - Model Registry: Gemini 3.8/3.1 & GitHub Copilot

    func testModelRegistryGeminiAndCopilotSupport() {
        // Verify default Gemini model is 3.8-flash
        let defaultGemini = ModelRegistry.geminiModel()
        XCTAssertEqual(defaultGemini, "gemini-3.8-flash")

        // Verify supported Gemini models include 3.8-flash and 3.1-pro
        let supported = ModelRegistry.supportedGeminiModels
        XCTAssertTrue(supported.contains("gemini-3.8-flash"))
        XCTAssertTrue(supported.contains("gemini-3.1-pro"))

        // Verify GitHub Copilot provider metadata
        let copilot = ModelProvider.gitHubCopilot
        XCTAssertTrue(copilot.displayName.contains("GitHub Copilot"))
        XCTAssertEqual(copilot.badge, "🐙 Copilot")
        XCTAssertFalse(copilot.isLocal)

        // Verify ModelRegistry default Copilot model
        XCTAssertEqual(ModelRegistry.copilotModel(), "gpt-4o")

        // Verify providers table includes GitHub Copilot
        let table = ModelRegistry.formatSupportedProvidersTable()
        XCTAssertTrue(table.contains("GitHub Copilot"))
        XCTAssertTrue(table.contains("gitHubCopilot"))
    }
}
