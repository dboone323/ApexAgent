import Foundation
import Synchronization
import CoreSpotlight
import UniformTypeIdentifiers

// MARK: - Spotlight Indexer (Phase 7 + Batch 30 Expansion)
//
// Indexes conversations, spaces, bots, routines, skills, and slash commands
// into Core Spotlight with rich attributes (keywords, contentType, contentURL)
// and deep-link handoff via Batch 24's DeepLinkRouter (`apexagent://`).

public enum SpotlightIndexer {

    public static let domainIdentifier = "com.apexagent.app.sessions"
    public static let spacesDomainIdentifier = "com.apexagent.app.spaces"
    public static let botsDomainIdentifier = "com.apexagent.app.bots"
    public static let routinesDomainIdentifier = "com.apexagent.app.routines"
    public static let skillsDomainIdentifier = "com.apexagent.app.skills"
    public static let commandsDomainIdentifier = "com.apexagent.app.commands"

    // Computed (not stored) — a stored static CSSearchableIndex is rejected by
    // Swift 6 strict concurrency (#MutableGlobalVariable).
    private static var index: CSSearchableIndex { CSSearchableIndex.default() }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var inMemoryItems: [String: CSSearchableItem] = [:]

    private static func recordIndexed(_ item: CSSearchableItem) {
        registryLock.lock()
        inMemoryItems[item.uniqueIdentifier] = item
        registryLock.unlock()
    }

    private static func recordRemoved(identifiers: [String]) {
        registryLock.lock()
        for id in identifiers {
            inMemoryItems.removeValue(forKey: id)
        }
        registryLock.unlock()
    }

    private static func recordRemoved(domains: [String]) {
        let domainSet = Set(domains)
        registryLock.lock()
        inMemoryItems = inMemoryItems.filter { _, item in
            guard let domain = item.domainIdentifier else { return true }
            return !domainSet.contains(domain)
        }
        registryLock.unlock()
    }

    /// Returns a currently indexed `CSSearchableItem` from the in-process catalog if present.
    public static func indexedItem(forUniqueIdentifier identifier: String) -> CSSearchableItem? {
        registryLock.lock()
        defer { registryLock.unlock() }
        return inMemoryItems[identifier]
    }

    // MARK: - Conversations

    public static func makeConversationItem(
        id: UUID,
        title: String,
        messages: [(role: String, content: String)],
        updatedAt: Date
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title.isEmpty ? "Apex Agent Session" : title
        attributes.contentDescription = messages
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")
            .prefix(8000)
            .description
        attributes.contentCreationDate = updatedAt
        attributes.contentModificationDate = updatedAt
        attributes.keywords = ["ApexAgent", "agent session", "conversation", title].filter { !$0.isEmpty }
        attributes.contentURL = DeepLinkRouter.url(for: .chat(id: id.uuidString))

        let item = CSSearchableItem(
            uniqueIdentifier: id.uuidString,
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    /// Index (or re-index) a conversation. Safe to call repeatedly — Spotlight
    /// upserts by uniqueIdentifier.
    public static func indexConversation(
        id: UUID,
        title: String,
        messages: [(role: String, content: String)],
        updatedAt: Date,
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        let item = makeConversationItem(id: id, title: title, messages: messages, updatedAt: updatedAt)
        recordIndexed(item)
        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index failed for \(id): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    /// Remove a deleted conversation from the index.
    public static func removeConversation(id: UUID, completion: (@Sendable (Error?) -> Void)? = nil) {
        recordRemoved(identifiers: [id.uuidString])
        index.deleteSearchableItems(withIdentifiers: [id.uuidString]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete failed for \(id): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    /// Remove every indexed ApexAgent session (Settings → privacy reset).
    public static func removeAllSessions(completion: (@Sendable (Error?) -> Void)? = nil) {
        recordRemoved(domains: [domainIdentifier])
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] purge failed: \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    // MARK: - Spaces & Bots

    /// Index a collaborative Space in Spotlight
    public static func indexSpace(id: UUID, name: String, summary: String, channels: [String]) {
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
    public static func removeSpace(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["space-\(id.uuidString)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete space failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    /// Index an Autonomous Bot Profile in Spotlight
    public static func indexBot(id: UUID, name: String, roleTitle: String, description: String) {
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
    public static func removeBot(id: UUID) {
        index.deleteSearchableItems(withIdentifiers: ["bot-\(id.uuidString)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete bot failed for \(id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Batch 30: Routines, Skills, and Slash Commands

    /// Builds a Spotlight searchable item for a Routine with deep-link `contentURL`.
    public static func makeRoutineItem(
        id: String,
        name: String,
        descriptionText: String,
        trigger: String,
        keywords: [String] = []
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Routine: \(name)"
        attributes.contentDescription = descriptionText
        attributes.keywords = ["ApexAgent", "routine", "automation", name, trigger] + keywords
        attributes.contentURL = DeepLinkRouter.url(for: .routine(id: id))

        let item = CSSearchableItem(
            uniqueIdentifier: "routine-\(id)",
            domainIdentifier: routinesDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    public static func indexRoutine(
        id: String,
        name: String,
        descriptionText: String,
        trigger: String = "manual",
        keywords: [String] = [],
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        let item = makeRoutineItem(id: id, name: name, descriptionText: descriptionText, trigger: trigger, keywords: keywords)
        recordIndexed(item)
        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index routine failed for \(id): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    public static func removeRoutine(id: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        recordRemoved(identifiers: ["routine-\(id)"])
        index.deleteSearchableItems(withIdentifiers: ["routine-\(id)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete routine failed for \(id): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    /// Builds a Spotlight searchable item for a Skill with deep-link `contentURL`.
    public static func makeSkillItem(
        name: String,
        description: String,
        triggerTerms: [String] = []
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Skill: \(name)"
        attributes.contentDescription = description
        attributes.keywords = ["ApexAgent", "skill", "capability", name] + triggerTerms
        attributes.contentURL = DeepLinkRouter.url(for: .skill(name: name))

        let item = CSSearchableItem(
            uniqueIdentifier: "skill-\(name)",
            domainIdentifier: skillsDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    public static func indexSkill(
        name: String,
        description: String,
        triggerTerms: [String] = [],
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        let item = makeSkillItem(name: name, description: description, triggerTerms: triggerTerms)
        recordIndexed(item)
        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index skill failed for \(name): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    public static func removeSkill(name: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        recordRemoved(identifiers: ["skill-\(name)"])
        index.deleteSearchableItems(withIdentifiers: ["skill-\(name)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete skill failed for \(name): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    /// Builds a Spotlight searchable item for a Slash Command with deep-link `contentURL`.
    public static func makeSlashCommandItem(
        name: String,
        summary: String,
        keywords: [String] = []
    ) -> CSSearchableItem {
        let normalizedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "Command: /\(normalizedName)"
        attributes.contentDescription = summary
        attributes.keywords = ["ApexAgent", "command", "slash command", normalizedName, "/\(normalizedName)"] + keywords
        attributes.contentURL = DeepLinkRouter.url(for: .command(name: normalizedName))

        let item = CSSearchableItem(
            uniqueIdentifier: "command-\(normalizedName)",
            domainIdentifier: commandsDomainIdentifier,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }

    public static func indexSlashCommand(
        name: String,
        summary: String,
        keywords: [String] = [],
        completion: (@Sendable (Error?) -> Void)? = nil
    ) {
        let item = makeSlashCommandItem(name: name, summary: summary, keywords: keywords)
        recordIndexed(item)
        index.indexSearchableItems([item]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] index command failed for \(name): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    public static func removeSlashCommand(name: String, completion: (@Sendable (Error?) -> Void)? = nil) {
        let normalizedName = name.hasPrefix("/") ? String(name.dropFirst()) : name
        recordRemoved(identifiers: ["command-\(normalizedName)"])
        index.deleteSearchableItems(withIdentifiers: ["command-\(normalizedName)"]) { error in
            if let error {
                AppLog.error(.spotlight, "[SpotlightIndexer] delete command failed for \(normalizedName): \(error.localizedDescription)")
            }
            completion?(error)
        }
    }

    // MARK: - Deep-Link Resolution & Activation Handoff

    /// Maps a Spotlight `uniqueIdentifier` to its canonical `apexagent://` deep-link URL.
    public static func deepLinkURL(forUniqueIdentifier identifier: String) -> URL? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("routine-") {
            let id = String(trimmed.dropFirst("routine-".count))
            guard !id.isEmpty else { return nil }
            return DeepLinkRouter.url(for: .routine(id: id))
        }
        if trimmed.hasPrefix("skill-") {
            let name = String(trimmed.dropFirst("skill-".count))
            guard !name.isEmpty else { return nil }
            return DeepLinkRouter.url(for: .skill(name: name))
        }
        if trimmed.hasPrefix("command-") {
            let name = String(trimmed.dropFirst("command-".count))
            guard !name.isEmpty else { return nil }
            return DeepLinkRouter.url(for: .command(name: name))
        }
        if trimmed.hasPrefix("chat-") {
            let id = String(trimmed.dropFirst("chat-".count))
            guard !id.isEmpty else { return nil }
            return DeepLinkRouter.url(for: .chat(id: id))
        }
        if UUID(uuidString: trimmed) != nil {
            return DeepLinkRouter.url(for: .chat(id: trimmed))
        }
        return nil
    }

    /// Handles a Spotlight search result continuation by resolving its `apexagent://` deep link
    /// and routing it through `DeepLinkNavigationState`.
    @MainActor
    @discardableResult
    public static func handleSpotlightActivation(
        uniqueIdentifier: String,
        navigationState: DeepLinkNavigationState? = nil
    ) -> Result<DeepLinkDestination, DeepLinkError>? {
        guard let url = deepLinkURL(forUniqueIdentifier: uniqueIdentifier) else {
            return nil
        }
        let targetState = navigationState ?? DeepLinkNavigationState.shared
        return targetState.handle(url)
    }
}