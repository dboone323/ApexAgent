import SwiftUI
import Accessibility

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var results: [DiagnosticItem] = []
    @State private var isRunning = false
    @State private var startedAt: Date?
    @State private var exportMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isRunning && results.isEmpty {
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
                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Analyzing system health...")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                            Spacer()
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        Divider()
                    }

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
                        .accessibilityIdentifier("diagnosticsDoneButton")
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        if let exportMessage {
                            Text(exportMessage)
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                        Button("Re-Run") { runDiagnostics() }
                            .disabled(isRunning)
                        Button("Copy Report") {
                            let report = DiagnosticManager.exportReport(results)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                            exportMessage = "Copied to clipboard!"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportMessage = nil }
                        }
                        .disabled(results.isEmpty)
                        Button("Export") {
                            let report = DiagnosticManager.exportReport(results)
                            let panel = NSSavePanel()
                            panel.nameFieldLabel = "Diagnostic Report"
                            panel.nameFieldStringValue = "diagnostics-report.json"
                            panel.allowedContentTypes = [.json]
                            if panel.runModal() == .OK, let url = panel.url {
                                try? report.write(to: url, atomically: true, encoding: .utf8)
                                exportMessage = "Saved to \(url.path)"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exportMessage = nil }
                            }
                        }
                        .disabled(results.isEmpty)
                    }
                }
            }
            .onAppear { runDiagnostics() }
            .frame(minWidth: 520, minHeight: 480)
        }
        .accessibilityIdentifier("diagnosticsSheet")
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
        exportMessage = nil
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
