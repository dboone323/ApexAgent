import SwiftUI
import Combine
import Accessibility

/// Observes the `AppLog` ring buffer for the Diagnostics "Recent Logs"
/// section. Production code path: the view's Clear button calls `clear()`,
/// `task`-driven `refresh()` keeps the section live while the sheet is open.
final class RecentLogsModel: ObservableObject {
    @Published private(set) var entries: [AppLogEntry] = []
    @Published private(set) var total = 0

    /// Pulls the newest entries from the real ring buffer.
    func refresh(limit: Int = 50) {
        entries = AppLog.recentEntries(limit: limit)
        total = AppLog.recentEntries().count
    }

    /// Clears the real ring buffer (bound to the section's Clear button).
    func clear() {
        AppLog.clearBuffer()
        refresh()
    }

    /// Counter text — pure form, unit-testable without touching the buffer.
    static func countText(shown: Int, total: Int) -> String {
        if total > shown { return "showing \(shown) of \(total)" }
        return total == 1 ? "1 entry" : "\(total) entries"
    }

    func countText() -> String {
        Self.countText(shown: entries.count, total: total)
    }
}

/// Observes `MetricDiagnosticsCenter` for the Diagnostics "Field Diagnostics" section.
final class FieldDiagnosticsModel: ObservableObject {
    @Published private(set) var summary: FieldHealthSummary
    @Published private(set) var recent: [MetricDiagnosticPayload] = []

    private let center: MetricDiagnosticsCenter

    init(center: MetricDiagnosticsCenter = .shared) {
        self.center = center
        self.summary = center.summary()
        self.recent = center.recentPayloads(limit: 20)
    }

    func refresh(limit: Int = 20) {
        summary = center.summary()
        recent = center.recentPayloads(limit: limit)
    }

    func clear() {
        center.clear()
        refresh()
    }
}

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recentLogs = RecentLogsModel()
    @StateObject private var fieldDiagnostics = FieldDiagnosticsModel()
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

                Divider()
                fieldDiagnosticsSection
                Divider()
                recentLogsSection
                    .frame(maxHeight: 240)
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

    /// Field diagnostics summary captured from MetricKit (`MetricDiagnosticsCenter`).
    private var fieldDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text("Field Diagnostics")
                    .font(AppTheme.Font.caption(12))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(fieldDiagnostics.summary.headline)
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                Spacer()
                Button("Clear") { fieldDiagnostics.clear() }
                    .accessibilityIdentifier("clearFieldDiagnosticsButton")
            }
            if !fieldDiagnostics.recent.isEmpty {
                HStack(spacing: 12) {
                    Text("Crashes: \(fieldDiagnostics.summary.crashCount)")
                    Text("Hangs: \(fieldDiagnostics.summary.hangCount)")
                    Text("CPU: \(fieldDiagnostics.summary.cpuExceptionCount)")
                    Text("Disk: \(fieldDiagnostics.summary.diskWriteExceptionCount)")
                    Text("Daily: \(fieldDiagnostics.summary.dailyMetricCount)")
                }
                .font(AppTheme.Font.caption(10))
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, 8)
        .accessibilityIdentifier("fieldDiagnosticsSection")
        .onAppear { fieldDiagnostics.refresh() }
    }

    /// Recent structured log entries from `AppLog`'s in-memory ring buffer.
    private var recentLogsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text("Recent Logs")
                    .font(AppTheme.Font.caption(12))
                    .foregroundStyle(AppTheme.Palette.textPrimary)
                Text(recentLogs.countText())
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                Spacer()
                Button("Clear") { recentLogs.clear() }
                    .accessibilityIdentifier("clearLogsButton")
            }
            if recentLogs.entries.isEmpty {
                Text("No log entries yet.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                    .accessibilityIdentifier("recentLogsEmpty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(recentLogs.entries.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 8) {
                                Text(entry.timestamp, style: .time)
                                    .font(AppTheme.Font.caption(10))
                                    .monospacedDigit()
                                    .foregroundStyle(AppTheme.Palette.textTertiary)
                                Text(entry.level.label)
                                    .font(AppTheme.Font.caption(10))
                                    .foregroundStyle(levelColor(entry.level))
                                    .frame(width: 52, alignment: .leading)
                                Text(entry.category.rawValue)
                                    .font(AppTheme.Font.caption(10))
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                                    .frame(width: 92, alignment: .leading)
                                Text(entry.message)
                                    .font(AppTheme.Font.caption(10))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(AppTheme.Palette.textPrimary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityIdentifier("logEntryRow")
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, 8)
        .accessibilityIdentifier("recentLogsSection")
        .task {
            // Live refresh while the sheet is open (never mutate during render).
            while !Task.isCancelled {
                recentLogs.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func levelColor(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .secondary
        case .notice: return .orange
        case .error: return .red
        case .fault: return .purple
        }
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
