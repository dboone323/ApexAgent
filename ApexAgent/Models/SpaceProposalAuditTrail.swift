// SpaceProposalAuditTrail.swift
// Batch 124: Cryptographic audit trail for SpacePageProposals (SHA-256 state
// hashes), unified diff chunk generator, and batch review operations.

import Foundation
import CryptoKit
import SwiftData

// MARK: - Unchecked Sendable Conformance for Model

extension SpacePageProposal: @unchecked Sendable {}

// MARK: - Diff Line & Unified Diff

public enum DiffLineKind: String, Sendable, Equatable, Codable {
    case unchanged, added, removed
}

public struct DiffLine: Sendable, Equatable {
    public let kind: DiffLineKind
    public let text: String
    public let lineNumber: Int  // 1-based, in proposed content for added/unchanged, original for removed

    public init(kind: DiffLineKind, text: String, lineNumber: Int) {
        self.kind = kind
        self.text = text
        self.lineNumber = lineNumber
    }
}

public struct UnifiedDiff: Sendable {
    public let lines: [DiffLine]
    public var addedCount: Int { lines.filter { $0.kind == .added }.count }
    public var removedCount: Int { lines.filter { $0.kind == .removed }.count }
    public var unchangedCount: Int { lines.filter { $0.kind == .unchanged }.count }
    public var summary: String { "+\(addedCount) -\(removedCount) lines" }

    public init(lines: [DiffLine]) {
        self.lines = lines
    }
}

// MARK: - Space Diff Engine

public final class SpaceDiffEngine: Sendable {
    public static func computeDiff(original: String, proposed: String) -> UnifiedDiff {
        let normOriginal = original
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let normProposed = proposed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let origLines = normOriginal.isEmpty ? [] : normOriginal.components(separatedBy: "\n")
        let propLines = normProposed.isEmpty ? [] : normProposed.components(separatedBy: "\n")

        // Limit to first 500 lines to prevent quadratic blowup
        let origLimited = Array(origLines.prefix(500))
        let propLimited = Array(propLines.prefix(500))

        let n = origLimited.count
        let m = propLimited.count

        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in 0..<n {
            for j in 0..<m {
                if origLimited[i] == propLimited[j] {
                    dp[i + 1][j + 1] = dp[i][j] + 1
                } else {
                    dp[i + 1][j + 1] = max(dp[i][j + 1], dp[i + 1][j])
                }
            }
        }

        var i = n
        var j = m
        var reversedLines: [DiffLine] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && origLimited[i - 1] == propLimited[j - 1] {
                reversedLines.append(
                    DiffLine(kind: .unchanged, text: origLimited[i - 1], lineNumber: j)
                )
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                reversedLines.append(
                    DiffLine(kind: .added, text: propLimited[j - 1], lineNumber: j)
                )
                j -= 1
            } else if i > 0 {
                reversedLines.append(
                    DiffLine(kind: .removed, text: origLimited[i - 1], lineNumber: i)
                )
                i -= 1
            }
        }

        return UnifiedDiff(lines: Array(reversedLines.reversed()))
    }
}

// MARK: - Proposal Audit Entry

public enum ProposalAuditAction: String, Sendable, Codable, CaseIterable {
    case staged, approved, denied, modified
}

public struct ProposalAuditEntry: Sendable, Codable {
    public let entryId: UUID
    public let proposalId: UUID
    public let pageId: UUID
    public let action: ProposalAuditAction
    public let actorName: String
    public let timestamp: Date
    public let stateHash: String   // SHA-256 hex of (proposalId + action.rawValue + proposedContent + timestamp ISO8601)
    public let proposedContentHash: String  // SHA-256 hex of proposedContent
    public let feedback: String?

    public init(
        entryId: UUID = UUID(),
        proposalId: UUID,
        pageId: UUID,
        action: ProposalAuditAction,
        actorName: String,
        timestamp: Date = Date(),
        stateHash: String,
        proposedContentHash: String,
        feedback: String? = nil
    ) {
        self.entryId = entryId
        self.proposalId = proposalId
        self.pageId = pageId
        self.action = action
        self.actorName = actorName
        self.timestamp = timestamp
        self.stateHash = stateHash
        self.proposedContentHash = proposedContentHash
        self.feedback = feedback
    }
}

// MARK: - Proposal Audit Trail Actor

public actor SpaceProposalAuditTrail {
    public static let shared = SpaceProposalAuditTrail()
    private var entries: [ProposalAuditEntry] = []

    public init() {}

    public static func sha256Hex(for string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func record(
        proposal: SpacePageProposal,
        action: ProposalAuditAction,
        actorName: String,
        feedback: String? = nil
    ) -> ProposalAuditEntry {
        let timestamp = Date()
        let formatter = ISO8601DateFormatter()
        let isoTimestamp = formatter.string(from: timestamp)
        let statePayload = proposal.id.uuidString + action.rawValue + proposal.proposedContent + isoTimestamp
        let stateHash = Self.sha256Hex(for: statePayload)
        let proposedContentHash = Self.sha256Hex(for: proposal.proposedContent)

        let entry = ProposalAuditEntry(
            proposalId: proposal.id,
            pageId: proposal.pageId,
            action: action,
            actorName: actorName,
            timestamp: timestamp,
            stateHash: stateHash,
            proposedContentHash: proposedContentHash,
            feedback: feedback
        )
        entries.append(entry)
        return entry
    }

    public func entries(for proposalId: UUID) -> [ProposalAuditEntry] {
        entries.filter { $0.proposalId == proposalId }
    }

    public func allEntries() -> [ProposalAuditEntry] {
        entries
    }

    public func verifyIntegrity(of entry: ProposalAuditEntry, proposal: SpacePageProposal) -> Bool {
        guard entry.proposalId == proposal.id else { return false }
        let recomputed = Self.sha256Hex(for: proposal.proposedContent)
        return recomputed == entry.proposedContentHash
    }

    public func clear() {
        entries.removeAll()
    }
}

// MARK: - Batch Reviewer

public final class SpaceProposalBatchReviewer: Sendable {
    @MainActor
    public static func approveAll(
        proposals: [SpacePageProposal],
        spaceManager: SpaceManager,
        editorName: String = "User"
    ) -> Int {
        var approvedCount = 0
        for proposal in proposals {
            if proposal.state == .pending {
                spaceManager.approveProposal(proposal, editorName: editorName)
                approvedCount += 1
            }
        }
        return approvedCount
    }

    @MainActor
    public static func denyAll(
        proposals: [SpacePageProposal],
        spaceManager: SpaceManager,
        reason: String = "Bulk denied"
    ) -> Int {
        var deniedCount = 0
        for proposal in proposals {
            if proposal.state == .pending {
                spaceManager.denyProposal(proposal, reason: reason)
                deniedCount += 1
            }
        }
        return deniedCount
    }
}
