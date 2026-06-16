import SwiftUI

enum AppTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    enum Font {
        static func body(_ size: CGFloat = 13) -> Font { .system(size: size) }
        static func caption(_ size: CGFloat = 11) -> Font { .system(size: size) }
        static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
        static func headline(_ size: CGFloat = 13, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight) }
    }

    enum Palette {
        static let accent = Color.purple
        static let success = Color.green
        static let warning = Color.orange
        static let critical = Color.red
        static let separator = Color(nsColor: .separatorColor)
        static let windowBackground = Color(nsColor: .windowBackgroundColor)
        static let controlBackground = Color(nsColor: .controlBackgroundColor)
        static let textPrimary = Color.primary
        static let textSecondary = Color.secondary
        static let textTertiary = Color.tertiary
    }

    enum CornerRadius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }
}
