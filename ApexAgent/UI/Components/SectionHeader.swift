import SwiftUI

struct SectionHeader: View {
    let title: String
    let icon: String?
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppTheme.Spacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .foregroundStyle(AppTheme.Palette.accent)
                        .imageScale(.medium)
                }
                Text(title)
                    .font(AppTheme.Font.headline())
            }
            if let subtitle {
                Text(subtitle)
                    .font(AppTheme.Font.caption())
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}
