import Foundation

// MARK: - Personal Context Index Service (Issue #85)

/// Local, permission-aware index service over personal context sources
/// (Mail, Calendar, Contacts, Files, Photos) with per-source toggles.
public final class PersonalContextIndex: Sendable {
    public static let shared = PersonalContextIndex()

    private let toggleStore: PersonalContextToggleStore
    private let adapters: [PersonalContextSource: any PersonalContextSourceAdapter]

    public init(
        toggleStore: PersonalContextToggleStore = .shared,
        adapters: [PersonalContextSource: any PersonalContextSourceAdapter]? = nil
    ) {
        self.toggleStore = toggleStore
        if let customAdapters = adapters {
            self.adapters = customAdapters
        } else {
            self.adapters = [
                .mail: MailContextAdapter(),
                .calendar: CalendarContextAdapter(),
                .contacts: ContactsContextAdapter(),
                .files: FilesContextAdapter(),
                .photos: PhotosContextAdapter()
            ]
        }
    }

    /// Whether the specified source is toggled on.
    public func isSourceEnabled(_ source: PersonalContextSource) -> Bool {
        toggleStore.isEnabled(source: source)
    }

    /// Update the toggle state for a specific source.
    public func setSourceEnabled(_ source: PersonalContextSource, enabled: Bool) {
        toggleStore.setEnabled(source: source, enabled: enabled)
    }

    /// Returns a map of all source toggles.
    public func allToggles() -> [PersonalContextSource: Bool] {
        toggleStore.allToggles()
    }

    /// Checks the current permission and availability status of a source.
    public func checkStatus(for source: PersonalContextSource) async -> PersonalContextSourceStatus {
        guard let adapter = adapters[source] else {
            return .unavailable(reason: "No adapter registered for \(source.displayName).")
        }
        return await adapter.checkStatus()
    }

    /// Checks the status of all sources.
    public func allStatuses() async -> [PersonalContextSource: PersonalContextSourceStatus] {
        var result: [PersonalContextSource: PersonalContextSourceStatus] = [:]
        for source in PersonalContextSource.allCases {
            result[source] = await checkStatus(for: source)
        }
        return result
    }

    /// Queries all toggled-on and available sources for matching items.
    ///
    /// - Parameters:
    ///   - text: The search query.
    ///   - limitPerSource: Maximum number of results to fetch per source (default: 10).
    /// - Returns: A `PersonalContextQueryResult` containing hits citing their source,
    ///   plus explicit status reports for toggled-off or degraded/unavailable sources.
    public func query(text: String, limitPerSource: Int = 10) async -> PersonalContextQueryResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        var hits: [PersonalContextHit] = []
        var sourceStatuses: [PersonalContextSource: PersonalContextSourceStatus] = [:]
        var toggledOffSources: Set<PersonalContextSource> = []
        var unavailableSources: [PersonalContextSource: String] = [:]

        for source in PersonalContextSource.allCases {
            // 1. Per-source toggle check
            guard toggleStore.isEnabled(source: source) else {
                toggledOffSources.insert(source)
                continue
            }

            // 2. Adapter resolution
            guard let adapter = adapters[source] else {
                let reason = "No adapter registered for \(source.displayName)."
                sourceStatuses[source] = .unavailable(reason: reason)
                unavailableSources[source] = reason
                continue
            }

            // 3. Permission & availability check
            let status = await adapter.checkStatus()
            sourceStatuses[source] = status

            guard status.isAvailable else {
                let reason = status.reason ?? "Unavailable"
                unavailableSources[source] = reason
                continue
            }

            // 4. If query is non-empty, perform read-only search
            if !trimmed.isEmpty {
                let sourceHits = await adapter.search(query: trimmed, limit: limitPerSource)
                hits.append(contentsOf: sourceHits)
            }
        }

        return PersonalContextQueryResult(
            query: trimmed,
            hits: hits,
            sourceStatuses: sourceStatuses,
            toggledOffSources: toggledOffSources,
            unavailableSources: unavailableSources
        )
    }
}
