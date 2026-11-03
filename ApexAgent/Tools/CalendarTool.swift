import Foundation
import FoundationModels
@preconcurrency import EventKit

// MARK: - Calendar Tool (EventKit Calendar Events)

struct CalendarTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "calendar"
    let description = """
    Reads, searches, creates, and deletes events from Apple Calendar using EventKit. \
    Supports listing upcoming events, finding events by title/keyword, and creating scheduled meetings or appointments.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'list' (view upcoming), 'create' (new event), 'search' (find events), or 'delete' (remove by ID/title)")
        var action: String

        @Guide(description: "Title / summary of the event")
        var title: String?

        @Guide(description: "Start date and time in ISO 8601 or natural format (e.g. '2026-08-27T09:00:00Z', '2026-08-27 14:00', or 'tomorrow 9am')")
        var startDate: String?

        @Guide(description: "End date and time in ISO 8601 or natural format. If omitted for 'create', defaults to 1 hour after start.")
        var endDate: String?

        @Guide(description: "Location or meeting link for the event")
        var location: String?

        @Guide(description: "Notes or description for the event")
        var notes: String?

        @Guide(description: "Number of days ahead to list events for 'list' action (default: 7)")
        var daysAhead: Int?

        @Guide(description: "Identifier of event to delete")
        var eventId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let action = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // In headless test mode or if user has not opted into contacts/calendar integration,
            // return graceful non-granted guidance without instantiating EKEventStore to avoid 4097 errors.
            if ContactsOptInManager.shared.isTestMode && !ContactsOptInManager.shared.isOptedIn {
                return "🔒 Calendar access was not granted. Please allow calendar access in macOS System Settings > Privacy & Security > Calendars."
            }

            let store = EKEventStore()
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await store.requestFullAccessToEvents()) ?? false
            } else {
                granted = (try? await store.requestAccess(to: .event)) ?? false
            }
            
            guard granted else {
                return "🔒 Calendar access was not granted. Please allow calendar access in macOS System Settings > Privacy & Security > Calendars."
            }

            switch action {
            case "list", "upcoming":
                return listEvents(store: store, daysAhead: arguments.daysAhead ?? 7)
            case "create", "add":
                return createEvent(store: store, title: arguments.title, startStr: arguments.startDate, endStr: arguments.endDate, location: arguments.location, notes: arguments.notes)
            case "search", "find":
                return searchEvents(store: store, query: arguments.title ?? arguments.notes ?? "", daysAhead: arguments.daysAhead ?? 30)
            case "delete", "remove":
                return deleteEvent(store: store, eventId: arguments.eventId, title: arguments.title)
            default:
                return "⚠️ Unknown calendar action: '\(arguments.action)'. Available actions: 'list', 'create', 'search', 'delete'."
            }
        }
    }

    // MARK: - Handlers

    private func listEvents(store: EKEventStore, daysAhead: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: max(daysAhead, 1), to: start) else {
            return "❌ Failed to calculate date range."
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        if events.isEmpty {
            return "📅 No calendar events scheduled for the next \(daysAhead) days."
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var output = "📅 Upcoming Calendar Events (Next \(daysAhead) Days):\n\n"
        for event in events {
            let startStr = df.string(from: event.startDate)
            let endStr = df.string(from: event.endDate)
            output += "• **\(event.title ?? "Untitled Event")**\n"
            output += "   ⏰ \(startStr) – \(endStr)\n"
            if let loc = event.location, !loc.isEmpty {
                output += "   📍 Location: \(loc)\n"
            }
            if let cal = event.calendar {
                output += "   📂 Calendar: \(cal.title)\n"
            }
            output += "   🆔 ID: `\(event.eventIdentifier ?? "")`\n\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func createEvent(store: EKEventStore, title: String?, startStr: String?, endStr: String?, location: String?, notes: String?) -> String {
        guard let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ Event title is required to create an event."
        }
        guard let startStr = startStr, let startDate = parseDate(startStr) else {
            return "❌ Valid start date required (ISO 8601 e.g. 2026-08-27T09:00:00Z or '2026-08-27 10:00')."
        }
        let endDate = endStr.flatMap { parseDate($0) } ?? startDate.addingTimeInterval(3600)

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = endDate
        event.location = location
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents

        do {
            try store.save(event, span: .thisEvent, commit: true)
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short
            return "✅ Successfully created event **\(title)** on \(df.string(from: startDate)) to \(df.string(from: endDate)) (ID: `\(event.eventIdentifier ?? "")`)."
        } catch {
            return "❌ Failed to save event: \(error.localizedDescription)"
        }
    }

    private func searchEvents(store: EKEventStore, query: String, daysAhead: Int) -> String {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let end = calendar.date(byAdding: .day, value: daysAhead, to: Date()) ?? Date()

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let lq = query.lowercased()
        let matches = store.events(matching: predicate).filter { event in
            (event.title?.lowercased().contains(lq) ?? false) ||
            (event.notes?.lowercased().contains(lq) ?? false) ||
            (event.location?.lowercased().contains(lq) ?? false)
        }.sorted { $0.startDate < $1.startDate }

        if matches.isEmpty {
            return "🔍 No events found matching keyword \"\(query)\"."
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        var output = "🔍 Found \(matches.count) event(s) matching \"\(query)\":\n\n"
        for event in matches {
            output += "• **\(event.title ?? "Untitled Event")** (\(df.string(from: event.startDate)))\n"
            if let loc = event.location, !loc.isEmpty { output += "   📍 \(loc)\n" }
            output += "   🆔 ID: `\(event.eventIdentifier ?? "")`\n\n"
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deleteEvent(store: EKEventStore, eventId: String?, title: String?) -> String {
        if let id = eventId, !id.isEmpty {
            if let event = store.event(withIdentifier: id) {
                do {
                    try store.remove(event, span: .thisEvent, commit: true)
                    return "🗑️ Successfully deleted event '\(event.title ?? id)'."
                } catch {
                    return "❌ Failed to delete event with ID \(id): \(error.localizedDescription)"
                }
            }
        }

        if let title = title, !title.isEmpty {
            let calendar = Calendar.current
            let start = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let end = calendar.date(byAdding: .day, value: 30, to: Date()) ?? Date()
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let matches = store.events(matching: predicate).filter { $0.title?.lowercased() == title.lowercased() }
            if let match = matches.first {
                do {
                    try store.remove(match, span: .thisEvent, commit: true)
                    return "🗑️ Successfully deleted event '\(match.title ?? title)'."
                } catch {
                    return "❌ Failed to delete event: \(error.localizedDescription)"
                }
            }
        }

        return "❌ Event not found to delete. Please provide a valid eventId or exact title."
    }

    private func parseDate(_ string: String) -> Date? {
        let isoFormatter = ISO8601DateFormatter()
        if let d = isoFormatter.date(from: string) { return d }
        
        let df = DateFormatter()
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "MM/dd/yyyy HH:mm",
            "MM/dd/yyyy"
        ]
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: string) { return d }
        }
        return nil
    }
}
