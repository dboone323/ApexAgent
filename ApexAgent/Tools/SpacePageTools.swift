import Foundation
import FoundationModels
import SwiftData

// MARK: - Space Read Page Tool
//
// Reads the content and metadata of a shared collaborative Space Page.

struct SpaceReadPageTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "space_read_page"
    let description = "Reads a collaborative Space Page by its title or ID, returning its markdown body and metadata."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The title or UUID of the Space Page to read")
        var pageTitleOrId: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let spaceMgr = SpaceManager.shared
                guard let space = spaceMgr.activeSpace else {
                    return "Error: No active Space selected."
                }

                let target = arguments.pageTitleOrId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let page = space.pages.first(where: {
                    $0.id.uuidString.lowercased() == target ||
                    $0.title.lowercased() == target ||
                    $0.title.lowercased().contains(target)
                }) else {
                    let available = space.pages.map { "'\($0.title)' (\($0.id))" }.joined(separator: ", ")
                    return "Error: Page '\(arguments.pageTitleOrId)' not found. Available pages in \(space.name): [\(available)]"
                }

                return """
                Page: \(page.title) (ID: \(page.id))
                Last Edited By: \(page.lastEditedByName) (\(page.updatedAt.formatted()))
                ---
                \(page.markdownBody)
                """
            }
        }
    }
}

// MARK: - Space Write Page Tool
//
// Proposes creating or updating a collaborative Space Page.
// Stages a pending SpacePageProposal for human review (Approve, Deny, Change).

struct SpaceWritePageTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "space_write_page"
    let description = "Proposes creating or updating a collaborative Space Page with new markdown content. Stages a review proposal for human approval."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The title or UUID of the Space Page to write or update")
        var pageTitleOrId: String

        @Guide(description: "The full proposed markdown body of the page")
        var content: String

        @Guide(description: "A short summary explaining what changed and why")
        var summary: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let spaceMgr = SpaceManager.shared
                guard let space = spaceMgr.activeSpace else {
                    return "Error: No active Space selected."
                }

                let target = arguments.pageTitleOrId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let existingPage = space.pages.first(where: {
                    $0.id.uuidString.lowercased() == target ||
                    $0.title.lowercased() == target
                })

                let pageId = existingPage?.id ?? UUID()
                let pageTitle = existingPage?.title ?? arguments.pageTitleOrId
                let original = existingPage?.markdownBody ?? ""

                let proposal = SpacePageProposal(
                    pageId: pageId,
                    pageTitle: pageTitle,
                    authorName: "Agent",
                    summary: arguments.summary.isEmpty ? "Proposed update to \(pageTitle)" : arguments.summary,
                    originalContent: original,
                    proposedContent: arguments.content,
                    state: .pending
                )
                proposal.space = space
                space.proposals.append(proposal)

                if let context = spaceMgr.modelContext {
                    context.insert(proposal)
                    try? context.save()
                }

                // If page doesn't exist yet, stage a draft page entity so it is discoverable
                if existingPage == nil {
                    let newPage = SpacePage(
                        id: pageId,
                        title: pageTitle,
                        markdownBody: "# \(pageTitle)\n\n*(Draft proposal pending human review)*",
                        lastEditedByName: "Agent (Pending)"
                    )
                    newPage.space = space
                    space.pages.append(newPage)
                    if let context = spaceMgr.modelContext {
                        context.insert(newPage)
                        try? context.save()
                    }
                }

                return "✅ Staged proposal #\(proposal.id.uuidString.prefix(6)) to update '\(pageTitle)'. The user can now Approve, Deny, or Change this proposal via the interactive review card."
            }
        }
    }
}

// MARK: - Space Propose Diff Tool
//
// Performs a surgical search-and-replace edit to an existing Space Page.
// Stages a pending proposal for human review.

struct SpaceProposeDiffTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "space_propose_diff"
    let description = "Proposes a surgical modification to a Space Page using exact text search and replacement. Stages a review proposal for human approval."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The title or UUID of the Space Page to modify")
        var pageTitleOrId: String

        @Guide(description: "Exact existing block of text within the page to find and replace")
        var searchContent: String

        @Guide(description: "Replacement block of text")
        var replaceContent: String

        @Guide(description: "Brief rationale explaining why this edit is proposed")
        var summary: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let spaceMgr = SpaceManager.shared
                guard let space = spaceMgr.activeSpace else {
                    return "Error: No active Space selected."
                }

                let target = arguments.pageTitleOrId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard let existingPage = space.pages.first(where: {
                    $0.id.uuidString.lowercased() == target ||
                    $0.title.lowercased() == target ||
                    $0.title.lowercased().contains(target)
                }) else {
                    return "Error: Page '\(arguments.pageTitleOrId)' not found in Space '\(space.name)'."
                }

                guard existingPage.markdownBody.contains(arguments.searchContent) else {
                    return "Error: 'searchContent' was not found in page '\(existingPage.title)'. Read the latest page content with space_read_page first."
                }

                let newContent = existingPage.markdownBody.replacingOccurrences(
                    of: arguments.searchContent,
                    with: arguments.replaceContent
                )

                let proposal = SpacePageProposal(
                    pageId: existingPage.id,
                    pageTitle: existingPage.title,
                    authorName: "Agent",
                    summary: arguments.summary.isEmpty ? "Proposed diff on \(existingPage.title)" : arguments.summary,
                    originalContent: existingPage.markdownBody,
                    proposedContent: newContent,
                    state: .pending
                )
                proposal.space = space
                space.proposals.append(proposal)

                if let context = spaceMgr.modelContext {
                    context.insert(proposal)
                    try? context.save()
                }

                return "✅ Staged diff proposal #\(proposal.id.uuidString.prefix(6)) on '\(existingPage.title)'. Waiting for human review (Approve, Deny, Change)."
            }
        }
    }
}
