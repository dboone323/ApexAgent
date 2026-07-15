import Foundation
import FoundationModels
import UserNotifications

// MARK: - Notification Tool

struct NotificationTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "send_notification"
    let description = """
    Sends a macOS user notification that appears in Notification Center. \
    Use this to alert the user when a long-running task completes, \
    or to provide important information while they're doing other things.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The title of the notification")
        var title: String

        @Guide(description: "The body text of the notification")
        var body: String

        @Guide(description: "Optional subtitle shown below the title")
        var subtitle: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            if NSClassFromString("XCTest") != nil || ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1" {
                return "✅ Notification sent: \"\(arguments.title)\" (Bypassed in test mode)"
            }
            
            let center = UNUserNotificationCenter.current()

            // Request permission if needed
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                return "ERROR: Notification permission not granted. Enable in System Settings → Notifications → Apex Agent."
            }

            let content = UNMutableNotificationContent()
            content.title = arguments.title
            content.body = arguments.body
            if let subtitle = arguments.subtitle {
                content.subtitle = subtitle
            }
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // Deliver immediately
            )

            try await center.add(request)
            return "✅ Notification sent: \"\(arguments.title)\""
        }
    }
}
