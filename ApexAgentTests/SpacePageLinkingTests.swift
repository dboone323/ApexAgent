// SpacePageLinkingTests.swift
// Batch 123: Tests for SpacePageLinker, SpaceProposalConflictDetector, and MarkdownValidator.

import XCTest
import SwiftData
@testable import ApexAgentCore

@MainActor
final class SpacePageLinkingTests: XCTestCase {

    // MARK: - 1. Wiki Link Extraction

    func testExtractLinksFindsAllWikiLinks() {
        let body = "# Intro\n\nSee [[Architecture]] for more.\nAlso [[Roadmap]] and [[Roadmap]]."
        let source = "Intro"

        let links = SpacePageLinker.extractLinks(from: body, sourceTitle: source)

        XCTAssertEqual(links.count, 3)
        let targetTitles = links.map(\.targetPageTitle)
        XCTAssertTrue(targetTitles.contains("Architecture"))
        XCTAssertTrue(targetTitles.contains("Roadmap"))
        XCTAssertEqual(links.filter { $0.targetPageTitle == "Roadmap" }.count, 2)
        XCTAssertEqual(links[0].sourcePageTitle, source)
        XCTAssertEqual(links[0].linkText, "[[Architecture]]")
    }

    func testExtractLinksReturnsEmptyForNoLinks() {
        let body = "# Title\nThis is pure markdown without any wiki links.\nJust plain text."
        let links = SpacePageLinker.extractLinks(from: body, sourceTitle: "Overview")

        XCTAssertTrue(links.isEmpty)
    }

    func testExtractLinksPreservesLineNumbers() {
        let body = "Line 1: Header\nLine 2: Blank or text\nLine 3: Link to [[Architecture]] here\nLine 4: Footer"
        let links = SpacePageLinker.extractLinks(from: body, sourceTitle: "Guide")

        XCTAssertEqual(links.count, 1)
        guard let firstLink = links.first else {
            XCTFail("Expected one link")
            return
        }
        XCTAssertEqual(firstLink.targetPageTitle, "Architecture")
        XCTAssertEqual(firstLink.lineNumber, 3)
    }

    // MARK: - 2. Graph Construction & Inbound Links

    func testBuildGraphCreatesInboundLinks() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "# Page A\nPoints to [[B]]."),
            (title: "B", body: "# Page B\nPoints to [[C]]."),
            (title: "C", body: "# Page C\nTerminal leaf page.")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)

        XCTAssertEqual(graph.count, 3)

        // Page B inbound and outbound links
        let pageB = graph["B"]
        XCTAssertNotNil(pageB)
        XCTAssertEqual(pageB?.inboundLinks.count, 1)
        XCTAssertEqual(pageB?.inboundLinks.first?.sourcePageTitle, "A")
        XCTAssertEqual(pageB?.outboundLinks.count, 1)
        XCTAssertEqual(pageB?.outboundLinks.first?.targetPageTitle, "C")

        // Page A
        let pageA = graph["A"]
        XCTAssertEqual(pageA?.inboundLinks.count, 0)
        XCTAssertEqual(pageA?.outboundLinks.count, 1)

        // Page C
        let pageC = graph["C"]
        XCTAssertEqual(pageC?.inboundLinks.count, 1)
        XCTAssertEqual(pageC?.outboundLinks.count, 0)
    }

    // MARK: - 3. Broken / Orphan Link Detection

    func testDetectBrokenLinksFindsOrphans() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "Check out [[NonExistentPage]] for details.")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)
        let broken = SpacePageLinker.detectBrokenLinks(graph: graph)

        XCTAssertEqual(broken.count, 1)
        XCTAssertEqual(broken.first?.targetPageTitle, "NonExistentPage")
        XCTAssertEqual(broken.first?.sourcePageTitle, "A")
    }

    func testDetectNoBrokenLinksWhenAllExist() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "Links to [[B]]."),
            (title: "B", body: "Links to [[A]].")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)
        let broken = SpacePageLinker.detectBrokenLinks(graph: graph)

        XCTAssertTrue(broken.isEmpty)
    }

    // MARK: - 4. Cycle Detection

    func testCycleDetectionFindsSimpleCycle() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "See [[B]]."),
            (title: "B", body: "See [[A]].")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)
        let cycles = SpacePageLinker.detectCycles(graph: graph)

        XCTAssertFalse(cycles.isEmpty)
        guard let firstCycle = cycles.first else {
            XCTFail("Expected at least one cycle")
            return
        }
        XCTAssertTrue(firstCycle.contains("A"))
        XCTAssertTrue(firstCycle.contains("B"))
    }

    func testCycleDetectionNoCycleInLinearChain() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "See [[B]]."),
            (title: "B", body: "See [[C]]."),
            (title: "C", body: "Leaf node.")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)
        let cycles = SpacePageLinker.detectCycles(graph: graph)

        XCTAssertTrue(cycles.isEmpty)
    }

    func testCycleDetectionThreeNodeCycle() {
        let pages: [(title: String, body: String)] = [
            (title: "A", body: "See [[B]]."),
            (title: "B", body: "See [[C]]."),
            (title: "C", body: "See [[A]].")
        ]

        let graph = SpacePageLinker.buildGraph(pages: pages)
        let cycles = SpacePageLinker.detectCycles(graph: graph)

        XCTAssertEqual(cycles.count, 1)
        let cycle = cycles[0]
        XCTAssertTrue(cycle.contains("A"))
        XCTAssertTrue(cycle.contains("B"))
        XCTAssertTrue(cycle.contains("C"))
    }

    // MARK: - 5. Proposal Conflict Detection

    func testConflictDetectionFindsPageConflict() {
        let pageId = UUID()
        let proposal1 = SpacePageProposal(
            id: UUID(),
            pageId: pageId,
            pageTitle: "Architecture",
            authorName: "Agent-1",
            summary: "Draft update 1",
            originalContent: "Original content",
            proposedContent: "Updated content by Agent 1",
            state: .pending
        )

        let proposal2 = SpacePageProposal(
            id: UUID(),
            pageId: pageId,
            pageTitle: "Architecture",
            authorName: "Agent-2",
            summary: "Draft update 2",
            originalContent: "Original content",
            proposedContent: "Updated content by Agent 2",
            state: .pending
        )

        let result = SpaceProposalConflictDetector.detectConflicts(
            incoming: proposal2,
            existingPending: [proposal1]
        )

        XCTAssertTrue(result.hasConflict)
        XCTAssertEqual(result.conflictingProposalIds, [proposal1.id])
        XCTAssertTrue(result.conflictDescription.contains("Architecture"))
    }

    func testConflictDetectionNoConflictDifferentPages() {
        let proposal1 = SpacePageProposal(
            id: UUID(),
            pageId: UUID(),
            pageTitle: "Architecture",
            authorName: "Agent-1",
            summary: "Draft update 1",
            originalContent: "Original content",
            proposedContent: "Updated content by Agent 1",
            state: .pending
        )

        let proposal2 = SpacePageProposal(
            id: UUID(),
            pageId: UUID(),
            pageTitle: "Roadmap",
            authorName: "Agent-2",
            summary: "Draft update 2",
            originalContent: "Original content",
            proposedContent: "Updated content by Agent 2",
            state: .pending
        )

        let result = SpaceProposalConflictDetector.detectConflicts(
            incoming: proposal2,
            existingPending: [proposal1]
        )

        XCTAssertFalse(result.hasConflict)
        XCTAssertTrue(result.conflictingProposalIds.isEmpty)
    }

    func testConflictDetectionIgnoresNonPendingProposals() {
        let pageId = UUID()
        let approvedProposal = SpacePageProposal(
            id: UUID(),
            pageId: pageId,
            pageTitle: "Architecture",
            authorName: "Agent-1",
            summary: "Approved update",
            originalContent: "Original content",
            proposedContent: "Updated content",
            state: .approved
        )

        let incoming = SpacePageProposal(
            id: UUID(),
            pageId: pageId,
            pageTitle: "Architecture",
            authorName: "Agent-2",
            summary: "New update",
            originalContent: "Updated content",
            proposedContent: "New revision",
            state: .pending
        )

        let result = SpaceProposalConflictDetector.detectConflicts(
            incoming: incoming,
            existingPending: [approvedProposal]
        )

        XCTAssertFalse(result.hasConflict)
        XCTAssertTrue(result.conflictingProposalIds.isEmpty)
    }

    // MARK: - 6. Line Conflict Detection

    func testLineConflictDetectionFindsOverlappingChanges() {
        let pageId = UUID()
        let original = "Line 1: Title\nLine 2: Intro\nLine 3: Base Spec\nLine 4: Conclusion"

        let proposalA = SpacePageProposal(
            pageId: pageId,
            pageTitle: "Spec",
            authorName: "Agent-A",
            summary: "Update spec",
            originalContent: original,
            proposedContent: "Line 1: Title\nLine 2: Intro\nLine 3: Spec Revision A\nLine 4: Conclusion"
        )

        let proposalB = SpacePageProposal(
            pageId: pageId,
            pageTitle: "Spec",
            authorName: "Agent-B",
            summary: "Update spec",
            originalContent: original,
            proposedContent: "Line 1: Title\nLine 2: Intro\nLine 3: Spec Revision B\nLine 4: Conclusion"
        )

        let conflicts = SpaceProposalConflictDetector.computeLineConflicts(
            proposalA: proposalA,
            proposalB: proposalB
        )

        XCTAssertEqual(conflicts, [3])
    }

    func testComputeLineConflictsEmptyWhenNoOverlap() {
        let pageId = UUID()
        let original = "Line 1\nLine 2\nLine 3\nLine 4"

        let proposalA = SpacePageProposal(
            pageId: pageId,
            pageTitle: "Doc",
            authorName: "Agent-A",
            summary: "Change line 2",
            originalContent: original,
            proposedContent: "Line 1\nLine 2 CHANGED\nLine 3\nLine 4"
        )

        let proposalB = SpacePageProposal(
            pageId: pageId,
            pageTitle: "Doc",
            authorName: "Agent-B",
            summary: "Change line 4",
            originalContent: original,
            proposedContent: "Line 1\nLine 2\nLine 3\nLine 4 CHANGED"
        )

        let conflicts = SpaceProposalConflictDetector.computeLineConflicts(
            proposalA: proposalA,
            proposalB: proposalB
        )

        XCTAssertTrue(conflicts.isEmpty)
    }

    // MARK: - 7. Markdown Validator

    func testMarkdownValidatorAcceptsCleanContent() {
        let clean = """
        # Documentation
        This is **bold** text and normal text.
        See [[Architecture]] for diagrams.

        | Column 1 | Column 2 |
        | -------- | -------- |
        | Value A  | Value B  |

        ```swift
        let x = 42
        ```
        """

        let result = MarkdownValidator.validate(clean)

        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }

    func testMarkdownValidatorDetectsUnclosedCodeFence() {
        let brokenFences = """
        # Code Snippet
        ```swift
        let x = 10
        print(x)
        """

        let result = MarkdownValidator.validate(brokenFences)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.lowercased().contains("fence") })
    }

    func testMarkdownValidatorDetectsBrokenWikiLink() {
        let brokenWiki = """
        # Notes
        Please refer to [[Unclosed for further instructions.
        """

        let result = MarkdownValidator.validate(brokenWiki)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.lowercased().contains("wiki-link") })
    }

    func testMarkdownValidatorDetectsUnclosedBold() {
        let brokenBold = """
        # Important
        This has **unclosed bold text in the paragraph.
        """

        let result = MarkdownValidator.validate(brokenBold)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.lowercased().contains("bold") })
    }

    func testMarkdownValidatorDetectsMalformedTable() {
        let malformedTable = """
        # Table
        | OnlyOnePipeWithoutClosing
        """

        let result = MarkdownValidator.validate(malformedTable)

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.lowercased().contains("table") })
    }

    func testLinkGraphLinkCountProperty() {
        let outbound = [
            SpacePageLink(sourcePageTitle: "Home", targetPageTitle: "About", linkText: "[[About]]", lineNumber: 1),
            SpacePageLink(sourcePageTitle: "Home", targetPageTitle: "Contact", linkText: "[[Contact]]", lineNumber: 2)
        ]
        let inbound = [
            SpacePageLink(sourcePageTitle: "Index", targetPageTitle: "Home", linkText: "[[Home]]", lineNumber: 5)
        ]
        let graphNode = SpacePageLinkGraph(
            pageTitle: "Home",
            outboundLinks: outbound,
            inboundLinks: inbound
        )

        XCTAssertEqual(graphNode.linkCount, 3)
    }
}
