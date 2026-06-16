import SwiftUI

struct TerminalStateView: View {
    enum State {
        case idle
        case running
        case error
    }

    let state: State
    let message: String?

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            stateImage
            Text(title)
                .font(AppTheme.Font.caption())
            Spacer()
            if let message {
                Text(message)
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(AppTheme.Spacing.sm)
        .background(AppTheme.Palette.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm, style: .continuous)
                .stroke(AppTheme.Palette.separator.opacity(0.4), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var stateImage: some View {
        switch state {
        case .idle:
            Circle()
                .fill(AppTheme.Palette.textTertiary)
                .frame(width: 6, height: 6)
                .blink(tag: "terminal_idle")
        case .running:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppTheme.Palette.critical)
                .font(.system(size: 12))
        }
    }

    private var title: String {
        switch state {
        case .idle: return "Terminal Idle"
        case .running: return "Running..."
        case .error: return "Shell Error"
        }
    }
}
