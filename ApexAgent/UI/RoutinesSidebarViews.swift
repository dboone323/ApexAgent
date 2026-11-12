import SwiftUI
import SwiftData

// MARK: - Routines Sidebar Section

struct RoutinesSidebarSection: View {
    @Environment(RoutineManager.self) private var envRoutineManager: RoutineManager?
    @Environment(\.modelContext) private var modelContext
    private var routineManager: RoutineManager {
        envRoutineManager ?? RoutineManager.shared
    }

    @Query(sort: \Routine.name) private var routines: [Routine]

    @State private var isAddingRoutine: Bool = false
    @State private var isRecordingRoutine: Bool = false
    @State private var isShowingRunHistory: Bool = false
    @State private var isConfirmingDelete: Bool = false
    @State private var routineToDelete: Routine?

    init() {}

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.accent)
                Text("Routines")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer()
                Text("\(routines.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button {
                    isAddingRoutine = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add New Routine")
                .accessibilityIdentifier("createRoutineSidebarButton")

                Menu {
                    Button {
                        isRecordingRoutine = true
                    } label: {
                        Label("Teach a Bot (Record Routine)", systemImage: "record.circle")
                    }

                    Button {
                        isShowingRunHistory = true
                    } label: {
                        Label("Execution History (\(routineManager.recentRuns.count))", systemImage: "clock.badge.checkmark")
                    }

                    Divider()

                    Button {
                        DeepLinkNavigationState.shared.apply(.routine(id: "all"))
                    } label: {
                        Label("Manage in Settings…", systemImage: "gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Content
            if routines.isEmpty {
                Button {
                    isAddingRoutine = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.dashed")
                            .font(.system(size: 11))
                        Text("Add Routine")
                            .font(.system(size: 11))
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(routines) { routine in
                            RoutineSidebarItem(
                                routine: routine,
                                onRun: {
                                    Task { @MainActor in
                                        await routineManager.runNow(routine)
                                    }
                                },
                                onToggle: {
                                    routineManager.toggle(routine)
                                },
                                onDelete: {
                                    routineToDelete = routine
                                    isConfirmingDelete = true
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 140)
            }
        }
        .sheet(isPresented: $isAddingRoutine) {
            CreateRoutineSheet()
        }
        .sheet(isPresented: $isRecordingRoutine) {
            RoutineRecordingSheet()
        }
        .sheet(isPresented: $isShowingRunHistory) {
            RoutineRunHistorySheet()
        }
        .confirmationDialog(
            "Delete Routine?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Routine", role: .destructive) {
                if let r = routineToDelete {
                    routineManager.delete(r)
                    routineToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                routineToDelete = nil
            }
        } message: {
            Text("This permanently removes the routine. This cannot be undone.")
        }
    }
}

// MARK: - Routine Sidebar Item

struct RoutineSidebarItem: View {
    let routine: Routine
    let onRun: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    init(
        routine: Routine,
        onRun: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.routine = routine
        self.onRun = onRun
        self.onToggle = onToggle
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: triggerIcon)
                .font(.system(size: 11))
                .foregroundStyle(routine.enabled ? AppTheme.Palette.accent : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(routine.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(routine.enabled ? .primary : .secondary)
                    .lineLimit(1)

                Text(routine.effectiveScheduleDescription)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            if isHovering {
                Button(action: onRun) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Run Now")
                .accessibilityIdentifier("runRoutine_\(routine.name)")
            }

            Toggle(isOn: Binding(
                get: { routine.enabled },
                set: { _ in onToggle() }
            )) {
                EmptyView()
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .scaleEffect(0.65)
            .frame(width: 32)
            .accessibilityIdentifier("routineSidebarToggle_\(routine.name)")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Run Now", action: onRun)
            Divider()
            Button(routine.enabled ? "Disable" : "Enable", action: onToggle)
            Button("Delete Routine", role: .destructive, action: onDelete)
        }
    }

    private var triggerIcon: String {
        switch routine.trigger {
        case .manual: return "hand.tap"
        case .timeInterval: return "clock"
        case .cron: return "calendar.badge.clock"
        case .onError: return "exclamationmark.triangle"
        case .onSuccess: return "checkmark.seal"
        case .onMessage: return "bubble.left"
        case .webhook: return "network"
        case .fileChange: return "folder"
        case .mailArrival: return "envelope"
        case .calendarEvent: return "calendar"
        case .lanPeer: return "antenna.radiowaves.left.and.right"
        }
    }
}
