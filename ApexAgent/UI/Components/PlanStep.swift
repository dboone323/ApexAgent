import SwiftUI

struct PlanStepRow: View {
    let step: PlanStep
    let index: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Step \(index + 1)")
                        .font(AppTheme.Font.headline(10, weight: .bold))
                        .foregroundStyle(statusColor)
                    Text(step.title)
                        .font(AppTheme.Font.body(12))
                        .foregroundStyle(step.status.lowercased() == "completed" ? AppTheme.Palette.textSecondary : AppTheme.Palette.textPrimary)
                        .strikethrough(step.status.lowercased() == "completed")
                        .lineLimit(3)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm, style: .continuous)
                .fill(AppTheme.Palette.controlBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.CornerRadius.sm, style: .continuous)
                .stroke(AppTheme.Palette.separator.opacity(0.5), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status.lowercased() {
        case "running":
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTheme.Palette.success)
                .font(.system(size: 14))
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppTheme.Palette.critical)
                .font(.system(size: 14))
        default:
            Image(systemName: "circle")
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .font(.system(size: 14))
        }
    }

    private var statusColor: Color {
        switch step.status.lowercased() {
        case "running": return AppTheme.Palette.accent
        case "completed": return AppTheme.Palette.success
        case "failed": return AppTheme.Palette.critical
        default: return AppTheme.Palette.textSecondary
        }
    }
}

struct PlanStepDetailView: View {
    let step: PlanStep

    var body: some View {
        Form {
            Section {
                Text("Step Details")
                    .font(AppTheme.Font.headline())
                Text(step.title)
                    .font(AppTheme.Font.body())
                Text("Status: \(step.status)")
                    .font(AppTheme.Font.caption())
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            if let result = step.result, !result.isEmpty {
                Section("Result") {
                    Text(result)
                        .font(AppTheme.Font.mono(12))
                        .textSelection(.enabled)
                }
            }
            if let error = step.error, !error.isEmpty {
                Section("Error") {
                    Text(error)
                        .font(AppTheme.Font.mono(12))
                        .foregroundStyle(AppTheme.Palette.critical)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(AppTheme.Spacing.md)
    }
}
