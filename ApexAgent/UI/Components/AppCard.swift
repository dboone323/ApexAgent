import SwiftUI

struct AppCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Palette.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.CornerRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.CornerRadius.md, style: .continuous)
                    .stroke(AppTheme.Palette.separator.opacity(0.5), lineWidth: 0.5)
            )
    }
}

struct DiagnosticCard: View {
    let title: String
    let subtitle: String
    let status: String
    let message: String

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                HStack {
                    Text(title)
                        .font(AppTheme.Font.headline())
                    Spacer()
                    statusBadge(title: status)
                }
                Text(subtitle)
                    .font(AppTheme.Font.caption())
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Text(message)
                    .font(AppTheme.Font.caption())
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func statusBadge(title: String) -> some View {
        let color: Color = {
            switch title.lowercased() {
            case "pass": return AppTheme.Palette.success
            case "warning": return AppTheme.Palette.warning
            case "fail": return AppTheme.Palette.critical
            default: return AppTheme.Palette.textTertiary
            }
        }()
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}
