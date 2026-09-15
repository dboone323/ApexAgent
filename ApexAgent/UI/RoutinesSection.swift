import SwiftUI
import SwiftData

// MARK: - RoutinesSection: persisted routine registry UI for Settings

/// Renders the list of user-defined Routines, mirroring the SwiftData-backed
/// registry.  Each row exposes the routine name, trigger type, schedule (if
/// applicable), and enable/disable / run-now / delete actions.
struct RoutinesSection: View {
    @Environment(RoutineManager.self) private var envRoutineManager: RoutineManager?
    @Environment(\.modelContext) private var modelContext
    private var routineManager: RoutineManager {
        envRoutineManager ?? RoutineManager.shared
    }

    @Query(sort: \Routine.name) private var routines: [Routine]

    @State private var isConfirmingDelete: Bool = false
    @State private var pendingRoutine: Routine?
    @State private var isRecordingRoutine: Bool = false
    @State private var isAddingRoutine: Bool = false

    var body: some View {
        Section("Routines") {
            if routines.isEmpty {
                EmptyView()
            } else {
                ForEach(routines) { routine in
                    RoutineRow(routine: routine) {
                        pendingRoutine = routine
                        isConfirmingDelete = true
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Add Routine") {
                    isAddingRoutine = true
                }
                
                Button("Teach a Bot (Record Routine)") {
                    isRecordingRoutine = true
                }
            }
        }
        .confirmationDialog(
            "Delete this routine?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Routine", role: .destructive) {
                if let routine = pendingRoutine {
                    routineManager.delete(routine)
                    pendingRoutine = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRoutine = nil
            }
        } message: {
            Text("This permanently removes the routine. This cannot be undone.")
        }
        .sheet(isPresented: $isRecordingRoutine) {
            RoutineRecordingSheet()
        }
        .sheet(isPresented: $isAddingRoutine) {
            CreateRoutineSheet()
        }
    }
}

// MARK: - RoutineRow: one persisted routine

struct RoutineRow: View {
    let routine: Routine
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(routine.name)
                .font(.headline)

            Text(routine.descriptionText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            HStack {
                HStack(spacing: 4) {
                    Image(systemName: triggerIcon)
                        .font(.caption)
                    Text(triggerLabel)
                        .font(.caption)
                }
                .foregroundStyle(.tertiary)

                if routine.trigger == .timeInterval && routine.scheduledMinutes > 0 {
                    Text("every \(routine.scheduledMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if routine.trigger == .cron {
                    Text(routine.effectiveScheduleDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Toggle(isOn: Binding(
                    get: { routine.enabled },
                    set: { _ in
                        RoutineManager.shared.toggle(routine)
                    }
                )) {
                    EmptyView()
                }
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Run Now") {
                Task { @MainActor in
                    await RoutineManager.shared.runNow(routine)
                }
            }
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    private var triggerIcon: String {
        switch routine.trigger {
        case .manual:      return "hand.tap"
        case .timeInterval: return "clock"
        case .cron:        return "calendar.badge.clock"
        case .onError:     return "exclamationmark.triangle"
        case .onSuccess:   return "checkmark.circle"
        case .onMessage:   return "message"
        case .webhook:     return "bolt"
        }
    }

    private var triggerLabel: String {
        switch routine.trigger {
        case .manual:      return "Manual"
        case .timeInterval: return "Every \(routine.scheduledMinutes) min"
        case .cron:        return "Cron Schedule"
        case .onError:     return "On failure"
        case .onSuccess:   return "On success"
        case .onMessage:   return "On message"
        case .webhook:     return "Webhook"
        }
    }
}

// MARK: - RoutineManager env key + accessors

private struct RoutineManagerEnvironmentKey: EnvironmentKey {
    static var defaultValue: RoutineManager {
        MainActor.assumeIsolated { RoutineManager() }
    }
}

extension EnvironmentValues {
    var routineManager: RoutineManager {
        get { self[RoutineManagerEnvironmentKey.self] }
        set { self[RoutineManagerEnvironmentKey.self] = newValue }
    }
}
