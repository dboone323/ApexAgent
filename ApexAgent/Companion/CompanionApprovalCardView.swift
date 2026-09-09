import SwiftUI

// MARK: - Companion Approval Card View (iOS Native)

public struct CompanionApprovalCardView: View {
    public let event: CompanionApprovalRelayEvent
    public let onDecision: (Bool, String?) -> Void

    @State private var notesText: String = ""
    @State private var isNotesExpanded: Bool = false

    public init(event: CompanionApprovalRelayEvent, onDecision: @escaping (Bool, String?) -> Void) {
        self.event = event
        self.onDecision = onDecision
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(riskColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(event.stageName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Risk Level: \(event.riskLevel.uppercased())")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(riskColor)
                }

                Spacer()

                Text(event.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Summary
            Text(event.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Action Buttons
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    onDecision(false, notesText.isEmpty ? nil : notesText)
                } label: {
                    Label("Reject", systemImage: "xmark.circle.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    onDecision(true, notesText.isEmpty ? nil : notesText)
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(riskColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var riskColor: Color {
        switch event.riskLevel.lowercased() {
        case "high", "critical": return .red
        case "medium": return .orange
        default: return .blue
        }
    }
}
