import Foundation
import FoundationModels
@preconcurrency import EventKit

// MARK: - Reminder Tool (EventKit Reminders)

struct ReminderTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "reminders"
    let description = """
    Reads, creates, completes, and manages reminders/to-do items in Apple Reminders using EventKit. \
    Supports listing active tasks, creating reminders with due dates and priorities, and marking tasks complete.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'list' (view incomplete tasks), 'create' (add task), 'complete' (mark done), or 'delete' (remove task)")
        var action: String

        @Guide(description: "Title / task description of the reminder")
        var title: String?

        @Guide(description: "Due date in ISO 8601 or standard format (e.g. '2026-08-27T17:00:00Z', '2026-08-28 09:00')")
        var dueDate: String?

        @Guide(description: "Priority level: 1 (High), 5 (Medium), 9 (Low), 0 (None)")
        var priority: Int?

        @Guide(description: "Notes or additional details for the reminder")
        var notes: String?

        @Guide(description: "Target list name (optional, defaults to default Reminders list)")
        var listName: String?

        @Guide(description: "Identifier of the reminder to complete or delete")
        var reminderId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let action = arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

            // In headless test mode or if user has not opted into contacts/calendar integration,
            // return graceful non-granted guidance without instantiating EKEventStore to avoid 4097 errors.
            if ContactsOptInManager.shared.isTestMode && !ContactsOptInManager.shared.isOptedIn {
                return "🔒 Reminders access was not granted. Please allow Reminders access in macOS System Settings > Privacy & Security > Reminders."
            }

            let store = EKEventStore()

            // Request authorization
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = (try? await store.requestFullAccessToReminders()) ?? false
            } else {
                granted = (try? await store.requestAccess(to: .reminder)) ?? false
            }

            guard granted else {
                return "🔒 Reminders access was not granted. Please allow Reminders access in macOS System Settings > Privacy & Security > Reminders."
            }

            switch action {
            case "list", "active", "all":
                return await self.listReminders(store: store, listName: arguments.listName)
            case "create", "add":
                return self.createReminder(store: store, title: arguments.title, dueStr: arguments.dueDate, priority: arguments.priority, notes: arguments.notes, listName: arguments.listName)
            case "complete", "done":
                return await self.completeReminder(store: store, reminderId: arguments.reminderId, title: arguments.title)
            case "delete", "remove":
                return await self.deleteReminder(store: store, reminderId: arguments.reminderId, title: arguments.title)
            default:
                return "⚠️ Unknown reminders action: '\(arguments.action)'. Available actions: 'list', 'create', 'complete', 'delete'."
            }
        }
    }

    // MARK: - Handlers

    private func listReminders(store: EKEventStore, listName: String?) async -> String {
        let calendars: [EKCalendar]?
        if let listName = listName, !listName.isEmpty {
            calendars = store.calendars(for: .reminder).filter { $0.title.lowercased() == listName.lowercased() }
        } else {
            calendars = nil
        }

        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { (reminders: [EKReminder]?) in
                guard let reminders = reminders, !reminders.isEmpty else {
                    continuation.resume(returning: "📝 No active reminders found.")
                    return
                }

                var output = "📝 Active Reminders (\(reminders.count)):\n\n"
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .short

                for reminder in reminders.prefix(25) {
                    let pIcon = reminder.priority == 1 ? "🔴 " : (reminder.priority == 5 ? "🟡 " : "")
                    output += "• \(pIcon)**\(reminder.title ?? "Untitled Reminder")**\n"
                    if let due = reminder.dueDateComponents?.date {
                        output += "   ⏰ Due: \(df.string(from: due))\n"
                    }
                    if let notes = reminder.notes, !notes.isEmpty {
                        output += "   📄 Note: \(notes)\n"
                    }
                    if let cal = reminder.calendar {
                        output += "   📂 List: \(cal.title)\n"
                    }
                    output += "   🆔 ID: `\(reminder.calendarItemIdentifier)`\n\n"
                }
                continuation.resume(returning: output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func createReminder(store: EKEventStore, title: String?, dueStr: String?, priority: Int?, notes: String?, listName: String?) -> String {
        guard let title = title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "❌ Reminder title is required."
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.priority = priority ?? 0

        if let listName = listName,
           let targetCal = store.calendars(for: .reminder).first(where: { $0.title.lowercased() == listName.lowercased() }) {
            reminder.calendar = targetCal
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        if let dueStr = dueStr, let dueDate = parseDate(dueStr) {
            let cal = Calendar.current
            reminder.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }

        do {
            try store.save(reminder, commit: true)
            return "✅ Created reminder **\(title)** in list \"\(reminder.calendar.title)\" (ID: `\(reminder.calendarItemIdentifier)`)."
        } catch {
            return "❌ Failed to save reminder: \(error.localizedDescription)"
        }
    }

    private func completeReminder(store: EKEventStore, reminderId: String?, title: String?) async -> String {
        if let id = reminderId, !id.isEmpty {
            if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
                item.isCompleted = true
                item.completionDate = Date()
                do {
                    try store.save(item, commit: true)
                    return "✅ Marked reminder **\(item.title ?? id)** as completed."
                } catch {
                    return "❌ Failed to complete reminder: \(error.localizedDescription)"
                }
            }
        }

        if let title = title, !title.isEmpty {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { (items: [EKReminder]?) in
                    guard let items = items, let match = items.first(where: { $0.title?.lowercased() == title.lowercased() }) else {
                        continuation.resume(returning: "❌ Reminder not found. Please provide a valid reminderId or exact title.")
                        return
                    }
                    match.isCompleted = true
                    match.completionDate = Date()
                    do {
                        try store.save(match, commit: true)
                        continuation.resume(returning: "✅ Marked reminder **\(match.title ?? title)** as completed.")
                    } catch {
                        continuation.resume(returning: "❌ Failed to complete reminder: \(error.localizedDescription)")
                    }
                }
            }
        }

        return "❌ Reminder not found. Please provide a valid reminderId or exact title."
    }

    private func deleteReminder(store: EKEventStore, reminderId: String?, title: String?) async -> String {
        if let id = reminderId, !id.isEmpty {
            if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
                do {
                    try store.remove(item, commit: true)
                    return "🗑️ Successfully deleted reminder '\(item.title ?? id)'."
                } catch {
                    return "❌ Failed to delete reminder: \(error.localizedDescription)"
                }
            }
        }

        if let title = title, !title.isEmpty {
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            return await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { (items: [EKReminder]?) in
                    guard let items = items, let match = items.first(where: { $0.title?.lowercased() == title.lowercased() }) else {
                        continuation.resume(returning: "❌ Reminder not found to delete.")
                        return
                    }
                    do {
                        try store.remove(match, commit: true)
                        continuation.resume(returning: "🗑️ Successfully deleted reminder '\(match.title ?? title)'.")
                    } catch {
                        continuation.resume(returning: "❌ Failed to delete reminder: \(error.localizedDescription)")
                    }
                }
            }
        }

        return "❌ Reminder not found to delete."
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
