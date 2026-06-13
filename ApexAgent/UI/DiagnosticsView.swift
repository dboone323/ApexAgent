import SwiftUI

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results: [DiagnosticItem] = []
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            VStack {
                if isRunning {
                    VStack(spacing: 16) {
                        ProgressView()
                        Text("Running system diagnostics self-check...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "checklist")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("No diagnostics run yet.")
                            .foregroundStyle(.secondary)
                        Button("Run Self-Check") {
                            runDiagnostics()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        Section("System Diagnostics Results") {
                            ForEach(results) { item in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(item.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Spacer()
                                        statusBadge(for: item.status)
                                    }
                                    Text(item.message)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    Text(item.category)
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("System Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Re-Run") {
                        runDiagnostics()
                    }
                    .disabled(isRunning)
                }
            }
            .onAppear {
                runDiagnostics()
            }
            .frame(minWidth: 460, minHeight: 480)
        }
    }

    private func runDiagnostics() {
        isRunning = true
        Task { @MainActor in
            let selfCheckItems = DiagnosticManager.runSelfCheck()
            self.results = selfCheckItems
            self.isRunning = false
        }
    }

    @ViewBuilder
    private func statusBadge(for status: DiagnosticStatus) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: status))
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(statusColor(for: status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor(for: status).opacity(0.15), in: Capsule())
    }

    private func statusColor(for status: DiagnosticStatus) -> Color {
        switch status {
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }
}
