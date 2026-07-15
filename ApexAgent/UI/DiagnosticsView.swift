import SwiftUI
import Accessibility

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results: [DiagnosticItem] = []
    @State private var isRunning = false
    @State private var startedAt: Date?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isRunning {
                    runningState
                } else if results.isEmpty {
                    EmptyState(
                        icon: "checklist",
                        title: "No diagnostics run yet.",
                        message: "Run a self-check to validate system health.",
                        actionTitle: "Run Self-Check",
                        action: runDiagnostics
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: AppTheme.Spacing.md)], spacing: AppTheme.Spacing.md) {
                            ForEach(results) { item in
                                DiagnosticCard(
                                    title: item.name,
                                    subtitle: item.category,
                                    status: item.status.rawValue,
                                    message: item.message
                                )
                            }
                        }
                        .padding(AppTheme.Spacing.md)
                    }
                }
            }
            .navigationTitle("System Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Re-Run") { runDiagnostics() }
                        .disabled(isRunning)
                }
            }
            .onAppear { runDiagnostics() }
            .frame(minWidth: 520, minHeight: 480)
        }
    }

    private var runningState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text("Running system diagnostics self-check...")
                .foregroundStyle(AppTheme.Palette.textSecondary)
            if let date = startedAt {
                Text("Started \(date, style: .time)")
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func runDiagnostics() {
        isRunning = true
        startedAt = Date()
        Task { @MainActor in
            let items = await DiagnosticManager.runSelfCheck()
            self.results = items
            self.isRunning = false
            
            let failures = items.filter { $0.status == .fail }
            if !failures.isEmpty {
                let failureNames = failures.map { $0.name }.joined(separator: ", ")
                let message = "Diagnostics completed. \(failures.count) check\(failures.count == 1 ? "" : "s") failed: \(failureNames)"
                AccessibilityNotification.Announcement(message).post()
            }
        }
    }
}
