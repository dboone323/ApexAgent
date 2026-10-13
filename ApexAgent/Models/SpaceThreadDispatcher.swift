// SpaceThreadDispatcher.swift
// Batch 127: Autonomous sub-task dispatcher and thread coordinator for
// collaborative SpaceChannels, managing investigation threads and summaries.

import Foundation
import SwiftData

/// The execution state of an autonomous thread investigation.
public enum ThreadInvestigationState: String, Sendable, Codable, Equatable {
    case active
    case concluded
    case stalled
}

/// Metadata describing an active, concluded, or stalled threaded investigation in a SpaceChannel.
public struct ThreadInvestigationMetadata: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID { threadParentId }
    public let threadParentId: UUID
    public let channelId: UUID
    public let taskPrompt: String
    public let assignedBotIds: [UUID]
    public var state: ThreadInvestigationState
    public let createdAt: Date
    public var completedAt: Date?
    public var summaryText: String?
    public var replyCount: Int

    public init(
        threadParentId: UUID,
        channelId: UUID,
        taskPrompt: String,
        assignedBotIds: [UUID],
        state: ThreadInvestigationState = .active,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        summaryText: String? = nil,
        replyCount: Int = 0
    ) {
        self.threadParentId = threadParentId
        self.channelId = channelId
        self.taskPrompt = taskPrompt
        self.assignedBotIds = assignedBotIds
        self.state = state
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.summaryText = summaryText
        self.replyCount = replyCount
    }

    public var formattedSummary: String {
        SpaceThreadDispatcher.formatSummary(for: self)
    }
}

/// Autonomous sub-task dispatcher and thread coordinator for collaborative SpaceChannels.
public actor SpaceThreadDispatcher {
    public static let shared = SpaceThreadDispatcher()

    private var investigations: [UUID: ThreadInvestigationMetadata] = [:]
    private var threadReplies: [UUID: [UUID]] = [:]

    public init() {}

    /// Starts a new investigation thread rooted at `rootMessageId`.
    public func startInvestigation(
        channelId: UUID,
        rootMessageId: UUID,
        prompt: String,
        assignedBotIds: [UUID]
    ) -> ThreadInvestigationMetadata {
        let metadata = ThreadInvestigationMetadata(
            threadParentId: rootMessageId,
            channelId: channelId,
            taskPrompt: prompt,
            assignedBotIds: assignedBotIds,
            state: .active,
            createdAt: Date(),
            completedAt: nil,
            summaryText: nil,
            replyCount: 0
        )
        investigations[rootMessageId] = metadata
        threadReplies[rootMessageId] = []
        return metadata
    }

    /// Records a child reply message to an existing investigation thread.
    public func recordReply(threadParentId: UUID, replyMessageId: UUID) throws {
        guard var investigation = investigations[threadParentId] else {
            throw NSError(
                domain: "SpaceThreadDispatcher",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Investigation thread not found for ID: \(threadParentId)"]
            )
        }
        var replies = threadReplies[threadParentId] ?? []
        replies.append(replyMessageId)
        threadReplies[threadParentId] = replies
        investigation.replyCount = replies.count
        investigations[threadParentId] = investigation
    }

    /// Concludes an investigation with a synthesized summary.
    public func concludeInvestigation(
        threadParentId: UUID,
        summary: String
    ) throws -> ThreadInvestigationMetadata {
        guard var investigation = investigations[threadParentId] else {
            throw NSError(
                domain: "SpaceThreadDispatcher",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Investigation thread not found for ID: \(threadParentId)"]
            )
        }
        investigation.state = .concluded
        investigation.completedAt = Date()
        investigation.summaryText = summary
        investigations[threadParentId] = investigation
        return investigation
    }

    /// Marks an investigation thread as stalled.
    public func markStalled(threadParentId: UUID) throws {
        guard var investigation = investigations[threadParentId] else {
            throw NSError(
                domain: "SpaceThreadDispatcher",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Investigation thread not found for ID: \(threadParentId)"]
            )
        }
        investigation.state = .stalled
        investigations[threadParentId] = investigation
    }

    /// Retrieves metadata for a specific investigation thread.
    public func getInvestigation(threadParentId: UUID) -> ThreadInvestigationMetadata? {
        investigations[threadParentId]
    }

    /// Returns all reply IDs recorded for a given thread parent.
    public func replies(for threadParentId: UUID) -> [UUID] {
        threadReplies[threadParentId] ?? []
    }

    /// Returns active investigations for a channel, ordered by creation time.
    public func activeInvestigations(for channelId: UUID) -> [ThreadInvestigationMetadata] {
        investigations.values
            .filter { $0.channelId == channelId && $0.state == .active }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Returns all investigations currently registered.
    public func allInvestigations() -> [ThreadInvestigationMetadata] {
        investigations.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Formats an investigation summary for injection back into the channel's root conversation.
    public func formatSummaryForChannelRoot(investigation: ThreadInvestigationMetadata) -> String {
        Self.formatSummary(for: investigation)
    }

    /// Formats an investigation summary using standard markdown.
    public static func formatSummary(for investigation: ThreadInvestigationMetadata) -> String {
        let summary = investigation.summaryText ?? "No summary provided."
        return [
            "🧵 **Thread Investigation Concluded**",
            "**Task:** \(investigation.taskPrompt)",
            "**Participants:** \(investigation.assignedBotIds.count) agent(s) · \(investigation.replyCount) replies",
            "---",
            summary
        ].joined(separator: "\n")
    }

    /// Resets all in-memory investigation state (used for testing and teardown).
    public func resetAll() {
        investigations.removeAll()
        threadReplies.removeAll()
    }
}
