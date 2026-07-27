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
            // UNUserNotificationCenter.current() raises an uncatchable ObjC
            // NSInternalInconsistencyException ("bundleProxyForCurrentProcess
            // is nil") in any process that is not a LaunchServices-registered
            // .app — e.g. the SwiftPM test runner (no bundle id at all) OR the
            // Xcode xctest agent (has a bundle id, but is not an .app bundle).
            // Guard the real constraint instead of crashing the process.
            guard Bundle.main.bundleIdentifier != nil,
                  Bundle.main.bundleURL.pathExtension == "app" else {
                return "ERROR: User notifications require a bundled app host (no bundle identifier in this process)."
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
