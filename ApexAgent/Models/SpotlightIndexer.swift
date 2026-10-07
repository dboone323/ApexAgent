import Foundation
import CoreSpotlight

// MARK: - Spotlight Session Indexer (Phase 7 — RAG over past sessions)
//
// Indexes completed agent conversations into Core Spotlight so (a) the user
// can find past agent sessions from system Spotlight, and (b) the agent's own
// SpotlightSearchTool can retrieve prior-session knowledge as RAG context.
// Complements SpotlightSearchTool (query side) — this is the write side.

enum SpotlightIndexer {

    static let domainIdentifier = "com.apexagent.app.sessions"
    // Computed (not stored) — a stored static CSSearchableIndex is rejected by
    // Swift 6 strict concurrency (#MutableGlobalVariable).
    private static var index: CSSearchableIndex { CSSearchableIndex.default() }

    /// Index (or re-index) a conversation. Safe to call repeatedly — Spotlight
    /// upserts by uniqueIdentifier. Fire-and-forget: indexing failures are
    /// logged, never surfaced to the chat flow.
    static func indexConversation(id: UUID, title: String, messages: [(role: String, content: String)], updatedAt: Date) {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title.isEmpty ? "Apex Agent Session" : title
        attributes.contentDescription = messages
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")
            .prefix(8000)
            .description
        attributes.contentCreationDate = updatedAt
        attributes.contentModificationDate = updatedAt
        attributes.keywords = ["ApexAgent", "agent session", "conversation"]

        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture

        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Remove a deleted conversation from the index.
    static func removeConversation(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: [id.uuidString]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Remove every indexed ApexAgent session (Settings → privacy reset).
    static func removeAllSessions() {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] purge failed: \(error.localizedDescription)")
            }
        }
    }

    static let spacesDomainIdentifier = "com.apexagent.app.spaces"
    static let botsDomainIdentifier = "com.apexagent.app.bots"

    /// Index a collaborative Space in Spotlight
    static func indexSpace(id: UUID, name: String, summary: String, channels: [String]) {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Space: \(name)"
        attributes.contentDescription = "\(summary)\nChannels: \(channels.joined(separator: ", "))"
        attributes.keywords = ["ApexAgent", "Space", name] + channels

        let item = CSSearchableItem(
            uniqueIdentifier: "space-\(id.uuidString)",
            domainIdentifier: spacesDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture

        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index space failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Remove a deleted Space from Spotlight
    static func removeSpace(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["space-\(id.uuidString)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete space failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Index an Autonomous Bot Profile in Spotlight
    static func indexBot(id: UUID, name: String, roleTitle: String, description: String) {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Bot: \(name) (\(roleTitle))"
        attributes.contentDescription = description
        attributes.keywords = ["ApexAgent", "Bot", "Agent", name, roleTitle]

        let item = CSSearchableItem(
            uniqueIdentifier: "bot-\(id.uuidString)",
            domainIdentifier: botsDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture

        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index bot failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Remove a deleted Bot from Spotlight
    static func removeBot(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["bot-\(id.uuidString)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete bot failed for \(id): \(error.localizedDescription)")
            }
        }
    }

}