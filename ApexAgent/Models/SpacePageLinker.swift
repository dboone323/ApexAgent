// SpacePageLinker.swift
// Batch 123: Wiki-link cross-reference graph, concurrent proposal conflict
// detection, and Markdown structural validator for collaborative Space pages.

import Foundation
import SwiftData

// MARK: - Wiki Link Representation

public struct SpacePageLink: Sendable, Equatable, Hashable {
    public let sourcePageTitle: String
    public let targetPageTitle: String
    public let linkText: String
    public let lineNumber: Int

    public init(
        sourcePageTitle: String,
        targetPageTitle: String,
        linkText: String,
        lineNumber: Int
    ) {
        self.sourcePageTitle = sourcePageTitle
        self.targetPageTitle = targetPageTitle
        self.linkText = linkText
        self.lineNumber = lineNumber
    }
}

// MARK: - Space Page Link Graph

public struct SpacePageLinkGraph: Sendable, Equatable {
    public let pageTitle: String
    public let outboundLinks: [SpacePageLink]
    public let inboundLinks: [SpacePageLink]
    public var linkCount: Int { outboundLinks.count + inboundLinks.count }

    public init(
        pageTitle: String,
        outboundLinks: [SpacePageLink] = [],
        inboundLinks: [SpacePageLink] = []
    ) {
        self.pageTitle = pageTitle
        self.outboundLinks = outboundLinks
        self.inboundLinks = inboundLinks
    }
}

// MARK: - Space Page Linker

public final class SpacePageLinker: Sendable {
    private init() {}

    /// Extracts all `[[...]]` wiki links from a markdown body line by line.
    /// Does not use regex.
    public static func extractLinks(from markdownBody: String, sourceTitle: String) -> [SpacePageLink] {
        var links: [SpacePageLink] = []
        let lines = markdownBody.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            var searchIndex = line.startIndex

            while let openRange = line[searchIndex...].range(of: "[[") {
                let afterOpen = openRange.upperBound
                if let closeRange = line[afterOpen...].range(of: "]]") {
                    let target = String(line[afterOpen..<closeRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let token = String(line[openRange.lowerBound..<closeRange.upperBound])
                    if !target.isEmpty {
                        links.append(SpacePageLink(
                            sourcePageTitle: sourceTitle,
                            targetPageTitle: target,
                            linkText: token,
                            lineNumber: lineNumber
                        ))
                    }
                    searchIndex = closeRange.upperBound
                } else {
                    break
                }
            }
        }

        return links
    }

    /// Builds a bi-directional wiki-link graph from an array of pages.
    public static func buildGraph(pages: [(title: String, body: String)]) -> [String: SpacePageLinkGraph] {
        var outboundMap: [String: [SpacePageLink]] = [:]
        var inboundMap: [String: [SpacePageLink]] = [:]

        for page in pages {
            outboundMap[page.title] = extractLinks(from: page.body, sourceTitle: page.title)
            if inboundMap[page.title] == nil {
                inboundMap[page.title] = []
            }
        }

        for page in pages {
            if let out = outboundMap[page.title] {
                for link in out {
                    inboundMap[link.targetPageTitle, default: []].append(link)
                }
            }
        }

        var graph: [String: SpacePageLinkGraph] = [:]
        for page in pages {
            graph[page.title] = SpacePageLinkGraph(
                pageTitle: page.title,
                outboundLinks: outboundMap[page.title] ?? [],
                inboundLinks: inboundMap[page.title] ?? []
            )
        }

        return graph
    }

    /// Returns all links whose targetPageTitle does not exist as a page in the graph.
    public static func detectBrokenLinks(graph: [String: SpacePageLinkGraph]) -> [SpacePageLink] {
        var brokenLinks: [SpacePageLink] = []
        let validTitles = Set(graph.keys)

        for pageTitle in graph.keys.sorted() {
            guard let pageGraph = graph[pageTitle] else { continue }
            for link in pageGraph.outboundLinks {
                if !validTitles.contains(link.targetPageTitle) {
                    brokenLinks.append(link)
                }
            }
        }

        return brokenLinks
    }

    /// Detects circular link chains (e.g. A -> B -> C -> A) using iterative DFS with visited and path tracking.
    /// Each cycle is returned as an ordered array of page titles, normalized to begin and end at the cycle's lexicographically smallest title.
    public static func detectCycles(graph: [String: SpacePageLinkGraph]) -> [[String]] {
        var detectedCycles: [[String]] = []
        var seenCycleKeys = Set<String>()

        struct StackFrame {
            let node: String
            var nextNeighborIndex: Int
        }

        let sortedNodes = graph.keys.sorted()

        for startNode in sortedNodes {
            var stack: [StackFrame] = [StackFrame(node: startNode, nextNeighborIndex: 0)]
            var path: [String] = [startNode]
            var pathSet: Set<String> = [startNode]

            while !stack.isEmpty {
                let currentIndex = stack.count - 1
                let currentNode = stack[currentIndex].node
                let neighbors = Array(Set(
                    graph[currentNode]?.outboundLinks
                        .map(\.targetPageTitle)
                        .filter { graph[$0] != nil } ?? []
                )).sorted()

                let neighborIndex = stack[currentIndex].nextNeighborIndex
                if neighborIndex < neighbors.count {
                    let neighbor = neighbors[neighborIndex]
                    stack[currentIndex].nextNeighborIndex += 1

                    if pathSet.contains(neighbor) {
                        if let cycleStart = path.firstIndex(of: neighbor) {
                            let cycleSlice = Array(path[cycleStart...])
                            let canonical = canonicalizeCycle(cycleSlice)
                            let key = canonical.joined(separator: "->")
                            if !seenCycleKeys.contains(key) {
                                seenCycleKeys.insert(key)
                                detectedCycles.append(canonical)
                            }
                        }
                    } else {
                        stack.append(StackFrame(node: neighbor, nextNeighborIndex: 0))
                        path.append(neighbor)
                        pathSet.insert(neighbor)
                    }
                } else {
                    stack.removeLast()
                    path.removeLast()
                    pathSet.remove(currentNode)
                }
            }
        }

        return detectedCycles
    }

    private static func canonicalizeCycle(_ nodes: [String]) -> [String] {
        guard !nodes.isEmpty else { return [] }
        guard let minIndex = nodes.indices.min(by: { nodes[$0] < nodes[$1] }) else {
            return nodes + [nodes[0]]
        }
        let rotated = Array(nodes[minIndex...]) + Array(nodes[..<minIndex])
        return rotated + [rotated[0]]
    }
}

// MARK: - Proposal Conflict Detection

public struct ProposalConflictResult: Sendable, Equatable {
    public let hasConflict: Bool
    public let conflictingProposalIds: [UUID]
    public let conflictDescription: String

    public init(
        hasConflict: Bool,
        conflictingProposalIds: [UUID],
        conflictDescription: String
    ) {
        self.hasConflict = hasConflict
        self.conflictingProposalIds = conflictingProposalIds
        self.conflictDescription = conflictDescription
    }
}

public final class SpaceProposalConflictDetector: Sendable {
    private init() {}

    /// Checks if `incoming` targets the same `pageId` as any proposal in `existingPending` whose state is `.pending`.
    public static func detectConflicts(
        incoming: SpacePageProposal,
        existingPending: [SpacePageProposal]
    ) -> ProposalConflictResult {
        let conflicting = existingPending.filter {
            $0.pageId == incoming.pageId && $0.state == .pending && $0.id != incoming.id
        }

        if conflicting.isEmpty {
            return ProposalConflictResult(
                hasConflict: false,
                conflictingProposalIds: [],
                conflictDescription: "No conflicts detected for page '\(incoming.pageTitle)'."
            )
        } else {
            let conflictIds = conflicting.map(\.id)
            let description = "Conflict detected: \(conflicting.count) existing pending proposal(s) already target page '\(incoming.pageTitle)' (ID: \(incoming.pageId)). Conflicting proposal ID(s): \(conflictIds.map(\.uuidString).joined(separator: ", "))."
            return ProposalConflictResult(
                hasConflict: true,
                conflictingProposalIds: conflictIds,
                conflictDescription: description
            )
        }
    }

    /// Splits both `proposedContent` strings into lines and returns 1-based line numbers
    /// where both proposals changed the line from the original content. Does not use regex.
    public static func computeLineConflicts(
        proposalA: SpacePageProposal,
        proposalB: SpacePageProposal
    ) -> [Int] {
        let original = !proposalA.originalContent.isEmpty ? proposalA.originalContent : proposalB.originalContent
        let origLines = original.components(separatedBy: "\n")
        let aLines = proposalA.proposedContent.components(separatedBy: "\n")
        let bLines = proposalB.proposedContent.components(separatedBy: "\n")

        let maxCount = max(origLines.count, max(aLines.count, bLines.count))
        var conflicts: [Int] = []

        for index in 0..<maxCount {
            let orig = index < origLines.count ? origLines[index] : nil
            let a = index < aLines.count ? aLines[index] : nil
            let b = index < bLines.count ? bLines[index] : nil

            let aChanged = (a != orig)
            let bChanged = (b != orig)

            if aChanged && bChanged {
                conflicts.append(index + 1)
            }
        }

        return conflicts
    }
}

// MARK: - Markdown Structural Validator

public struct MarkdownValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let errors: [String]

    public init(isValid: Bool, errors: [String]) {
        self.isValid = isValid
        self.errors = errors
    }
}

public struct MarkdownValidator: Sendable {
    public typealias MarkdownValidationResult = ApexAgentCore.MarkdownValidationResult

    /// Validates markdown structure:
    /// 1. Unclosed code fences (odd count of ```)
    /// 2. Unclosed bold formatting (odd count of **)
    /// 3. Malformed tables (lines starting with '|' with fewer than 2 '|' characters)
    /// 4. Broken wiki-links ('[[' without matching ']]' on same line)
    public static func validate(_ body: String) -> ApexAgentCore.MarkdownValidationResult {
        var errors: [String] = []

        // 1. Unclosed code fences: count backtick fence openings (```), verify even count
        var fenceCount = 0
        var fenceSearch = body.startIndex..<body.endIndex
        while let range = body.range(of: "```", range: fenceSearch) {
            fenceCount += 1
            fenceSearch = range.upperBound..<body.endIndex
        }
        if fenceCount % 2 != 0 {
            errors.append("Unclosed code fence: found odd count (\(fenceCount)) of triple-backtick '```' markers.")
        }

        // 2. Unclosed bold: count ** pairs are even
        var boldCount = 0
        var boldSearch = body.startIndex..<body.endIndex
        while let range = body.range(of: "**", range: boldSearch) {
            boldCount += 1
            boldSearch = range.upperBound..<body.endIndex
        }
        if boldCount % 2 != 0 {
            errors.append("Unclosed bold: found odd count (\(boldCount)) of '**' markers.")
        }

        // 3. Malformed tables & 4. Broken wiki-links
        let lines = body.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Table validation: if a line starts with |, verify it has at least 2 | characters
            if trimmed.hasPrefix("|") {
                let pipeCount = trimmed.filter { $0 == "|" }.count
                if pipeCount < 2 {
                    errors.append("Malformed table at line \(lineNumber): line starts with '|' but has fewer than 2 '|' characters.")
                }
            }

            // Wiki-link validation: detect [[ without matching ]] on the same line
            var searchIdx = line.startIndex
            while let openRange = line[searchIdx...].range(of: "[[") {
                let afterOpen = openRange.upperBound
                if let closeRange = line[afterOpen...].range(of: "]]") {
                    searchIdx = closeRange.upperBound
                } else {
                    errors.append("Broken wiki-link at line \(lineNumber): found '[[' without matching ']]' on the same line.")
                    break
                }
            }
        }

        return ApexAgentCore.MarkdownValidationResult(isValid: errors.isEmpty, errors: errors)
    }
}
