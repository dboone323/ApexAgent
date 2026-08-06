import SwiftUI

struct ToolActivityView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @State private var selectedEvent: ToolEvent?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Activity")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !orchestrator.toolEvents.isEmpty {
                    Button {
                        orchestrator.clearToolEvents()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear activity log")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if orchestrator.toolEvents.isEmpty {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text("No activity yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.quaternary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(orchestrator.toolEvents) { event in
                    ToolEventRow(event: event)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowBackground(
                            selectedEvent?.id == event.id
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                        )
                        .onTapGesture { selectedEvent = selectedEvent?.id == event.id ? nil : event }
                }
                .listStyle(.plain)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("toolActivityView")
    }
}

// MARK: - Tool Event Row

struct ToolEventRow: View {
    let event: ToolEvent
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusIcon(status: event.status)

                VStack(alignment: .leading, spacing: 1) {
                    Text(event.toolName)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text(event.timestamp.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Arguments
                    if !event.arguments.isEmpty && event.arguments != "{}" {
                        Group {
                            Text("Arguments")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(event.arguments)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(8)
                        }
                    }

                    // Result
                    if let result = event.result {
                        Group {
                            Text("Result")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(result)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(10)
                        }
                    }
                }
                .padding(.leading, 20)
                .padding(.top, 4)
                .textSelection(.enabled)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }
}

// MARK: - Status Icon

struct StatusIcon: View {
    let status: ToolStatus

    var body: some View {
        ZStack {
            switch status {
            case .running:
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Running")
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Success")
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Failed")
            case .awaitingConfirmation:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Awaiting confirmation")
            case .denied:
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Denied")
            }
        }
        .frame(width: 14, height: 14)
    }
}
