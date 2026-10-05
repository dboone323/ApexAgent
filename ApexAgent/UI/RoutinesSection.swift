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
    @State private var isShowingRunHistory: Bool = false

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

                Button("Execution History (\(routineManager.recentRuns.count))") {
                    isShowingRunHistory = true
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
        .sheet(isPresented: $isShowingRunHistory) {
            RoutineRunHistorySheet()
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
// MARK: - Routine Run Receipts & History

struct RoutineRunHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RoutineManager.self) private var envRoutineManager: RoutineManager?
    private var routineManager: RoutineManager {
        envRoutineManager ?? RoutineManager.shared
    }
    @State private var selectedRun: RoutineRun?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if routineManager.recentRuns.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 36))
                            .foregroundStyle(.tertiary)
                        Text("No Execution Receipts Yet")
                            .font(.headline)
                        Text("When routines run automatically or via 'Run Now', durable execution receipts, status, and output will appear here.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else {
                    List {
                        ForEach(routineManager.recentRuns) { run in
                            RoutineRunRow(run: run)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedRun = run
                                }
                        }
                    }
                }
            }
            .navigationTitle("Routine Execution Receipts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                if !routineManager.recentRuns.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear Receipts") {
                            routineManager.clearRuns()
                        }
                    }
                }
            }
            .sheet(item: $selectedRun) { run in
                RoutineRunDetailSheet(run: run)
            }
        }
        .frame(minWidth: 540, minHeight: 400)
    }
}

struct RoutineRunRow: View {
    let run: RoutineRun

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusBadge

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(run.routineName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(run.startedAt, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Text(run.trigger.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Text("•")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Text(run.formattedDuration)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if let error = run.error {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch run.status {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 16))
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))
        case .queued:
            Image(systemName: "hourglass.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 16))
        case .cancelled:
            Image(systemName: "slash.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
    }
}

struct RoutineRunDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: RoutineRun

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.routineName)
                                .font(.title2.bold())
                            Text("Trigger: \(run.trigger.rawValue) • Status: \(run.status.rawValue.capitalized)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Timing")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            VStack(alignment: .leading) {
                                Text("Started")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(run.startedAt.formatted())
                                    .font(.system(size: 12))
                            }
                            if let finishedAt = run.finishedAt {
                                VStack(alignment: .leading) {
                                    Text("Finished")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(finishedAt.formatted())
                                        .font(.system(size: 12))
                                }
                            }
                            VStack(alignment: .leading) {
                                Text("Duration")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Text(run.formattedDuration)
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Prompt")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(run.prompt)
                            .font(.system(size: 12, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(8)
                    }

                    if let output = run.output {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Output Receipt")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            Text(output)
                                .font(.system(size: 12, design: .monospaced))
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(8)
                        }
                    }

                    if let error = run.error {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Error")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundStyle(.red)
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Receipt Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}

