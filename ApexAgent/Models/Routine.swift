import Foundation
import SwiftData

// MARK: - Routine: A persisted, named routine (visible in Settings + executable by RoutineManager)

/// A Routine is a named, reusable automation that the user can trigger manually,
/// on a time interval, or as a reaction to a chat outcome (build failure, tool
/// success, etc.).  Unlike Skills (which are shell scripts with JSON schemas),
/// a Routine is a *prompt + routing instruction* executed by a Bot through the
/// shared AgentOrchestrator — the same path a normal chat message takes.
///
/// Stored in SwiftData so it persists across launches and shows up in Settings
/// alongside Skills.
@Model
final class Routine {
    @Attribute(.unique) var name: String
    var descriptionText: String        // the prompt/signature of the routine
    var trigger: RoutineTrigger
    var scheduledMinutes: Int          // used when trigger == .timeInterval
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        descriptionText: String,
        trigger: RoutineTrigger = .manual,
        scheduledMinutes: Int = 0,
        enabled: Bool = true
    ) {
        self.name = name
        self.descriptionText = descriptionText
        self.trigger = trigger
        self.scheduledMinutes = scheduledMinutes
        self.enabled = enabled
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}

// MARK: - RoutineTrigger: when a Routine fires

enum RoutineTrigger: String, Codable, CaseIterable {
    case manual              = "Manual"                  // user presses "Run now"
    case timeInterval        = "Every N minutes"         // Timer-based; scheduledMinutes > 0
    case onError             = "When build/tool fails"   // reaction to a failure signal
    case onSuccess           = "When build/tool succeeds"// reaction to a success signal
    case onMessage           = "On specific message"     // (placeholder — Phase 3 hook)
}
