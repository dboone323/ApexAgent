import SwiftUI

struct PlayPauseButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.accent)
                .frame(width: 28, height: 28)
                .background(AppTheme.Palette.accent.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(isPaused ? "Resume" : "Pause")
    }
}

struct TerminalToolbar: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Binding var isPaused: Bool
    let onCopy: () -> Void
    let onClear: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Label("Terminal Console", systemImage: "terminal")
                .font(AppTheme.Font.headline(11, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.textSecondary)

            Spacer()

            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .font(AppTheme.Font.caption(10))
            .foregroundStyle(AppTheme.Palette.textSecondary)

            Button(action: onClear) {
                Label("Clear", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .font(AppTheme.Font.caption(10))
            .foregroundStyle(AppTheme.Palette.textSecondary)

            PlayPauseButton(isPaused: isPaused) {
                isPaused.toggle()
            }

            Button(action: onReset) {
                Label("Reset Shell", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(AppTheme.Font.caption(10))
            .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
        .background(AppTheme.Palette.controlBackground)
    }
}
