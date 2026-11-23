import Foundation

// MARK: - Personal Context Index Models (Issue #85)

/// The five personal context sources available in ApexAgent.
public enum PersonalContextSource: String, CaseIterable, Sendable, Codable, Identifiable, Hashable {
    case mail = "mail"
    case calendar = "calendar"
    case contacts = "contacts"
    case files = "files"
    case photos = "photos"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .files: return "Files"
        case .photos: return "Photos"
        }
    }

    public var frameworkDescription: String {
        switch self {
        case .mail:
            return "Apple Mail (No public read API on macOS; reports unavailable)"
        case .calendar:
            return "EventKit (Calendars & Reminders)"
        case .contacts:
            return "Contacts framework via ContactsOptInManager"
        case .files:
            return "Foundation FileManager (Local file documents)"
        case .photos:
            return "PhotoKit (Photos library)"
        }
    }
}

/// The permission and availability status of a personal context source.
public enum PersonalContextSourceStatus: Sendable, Equatable, Codable {
    case available
    case unavailable(reason: String)
    case denied(reason: String)
    case notDetermined(reason: String)
    case restricted(reason: String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .available:
            return nil
        case .unavailable(let reason),
             .denied(let reason),
             .notDetermined(let reason),
             .restricted(let reason):
            return reason
        }
    }

    public var displayString: String {
        switch self {
        case .available:
            return "Available"
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        case .denied(let reason):
            return "Denied: \(reason)"
        case .notDetermined(let reason):
            return "Not Determined: \(reason)"
        case .restricted(let reason):
            return "Restricted: \(reason)"
        }
    }
}

/// A search hit returned from the personal context index, citing its source.
public struct PersonalContextHit: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let source: PersonalContextSource
    public let title: String
    public let snippet: String
    public let timestamp: Date?
    public let metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        source: PersonalContextSource,
        title: String,
        snippet: String,
        timestamp: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.snippet = snippet
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

/// Result of querying the personal context index.
public struct PersonalContextQueryResult: Sendable, Equatable {
    public let query: String
    public let hits: [PersonalContextHit]
    public let sourceStatuses: [PersonalContextSource: PersonalContextSourceStatus]
    public let toggledOffSources: Set<PersonalContextSource>
    public let unavailableSources: [PersonalContextSource: String]

    public init(
        query: String,
        hits: [PersonalContextHit],
        sourceStatuses: [PersonalContextSource: PersonalContextSourceStatus],
        toggledOffSources: Set<PersonalContextSource>,
        unavailableSources: [PersonalContextSource: String]
    ) {
        self.query = query
        self.hits = hits
        self.sourceStatuses = sourceStatuses
        self.toggledOffSources = toggledOffSources
        self.unavailableSources = unavailableSources
    }
}
