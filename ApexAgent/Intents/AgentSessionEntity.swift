import AppIntents
import Foundation
import SwiftData

// MARK: - Agent Session Entities & Queries (Phase 8 — Siri / Shortcuts)
//
// Exposes past agent sessions to Siri and Shortcuts as first-class entities,
// per Apple's "Build intelligent Siri experiences with App Schemas" guidance:
// AppEntity + EntityQuery so Shortcuts can list, search, and reference agent
// conversations; plus intents to fetch recent sessions and search them.
// Complements AskApexAgentIntent (the action) with entity-shaped read access.

// MARK: Entity

@available(macOS 13.0, *)
struct AgentSessionEntity: AppEntity, Identifiable {
    nonisolated static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Apex Agent Session")
    }
    nonisolated static var defaultQuery: AgentSessionQuery { AgentSessionQuery() }

    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(messageCount) messages · \(updatedAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

// MARK: Query

@available(macOS 13.0, *)
struct AgentSessionQuery: EntityQuery, EntityStringQuery {

    @MainActor
    private func allSessions() -> [AgentSessionEntity] {
        guard let context = AppDelegate.sharedOrchestrator.modelContext else { return [] }
        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let conversations = (try? context.fetch(descriptor)) ?? []
        return conversations.map {
            AgentSessionEntity(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messages.count)
        }
    }

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AgentSessionEntity] {
        let wanted = Set(identifiers)
        return allSessions().filter { wanted.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [AgentSessionEntity] {
        let needle = string.lowercased()
        return allSessions().filter { $0.title.lowercased().contains(needle) }
    }

    @MainActor
    func suggestedEntities() async throws -> [AgentSessionEntity] {
        Array(allSessions().prefix(5))
    }

    @MainActor
    func sessions(limit: Int) -> [AgentSessionEntity] {
        Array(allSessions().prefix(max(1, limit)))
    }
}

// MARK: Recent sessions intent

@available(macOS 13.0, *)
struct RecentAgentSessionsIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Get Recent Apex Agent Sessions" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Returns the most recent Apex Agent conversations.")
    }

    @Parameter(title: "Limit", description: "Maximum number of sessions to return.", default: 5)
    var limit: Int

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Get the last \(\.$limit) Apex Agent sessions")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AgentSessionEntity]> {
        let capped = AgentSessionQuery().sessions(limit: limit)
        return .result(value: capped)
    }
}

// MARK: Search sessions intent

@available(macOS 13.0, *)
struct SearchAgentSessionsIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Search Apex Agent Sessions" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Searches past Apex Agent conversations by title and content.")
    }

    @Parameter(title: "Query", description: "Text to search for in past sessions.")
    var query: String

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Search Apex Agent sessions for \(\.$query)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[AgentSessionEntity]> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return .result(value: []) }
        guard let context = AppDelegate.sharedOrchestrator.modelContext else { return .result(value: []) }

        let descriptor = FetchDescriptor<Conversation>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        let conversations = (try? context.fetch(descriptor)) ?? []
        let matches = conversations.filter { conv in
            if conv.title.lowercased().contains(needle) { return true }
            return conv.messages.contains { $0.content.lowercased().contains(needle) }
        }
        let entities = matches.prefix(20).map {
            AgentSessionEntity(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messages.count)
        }
        return .result(value: Array(entities))
    }
}
