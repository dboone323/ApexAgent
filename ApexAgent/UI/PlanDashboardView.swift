import SwiftUI

struct PlanDashboardView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.indent")
                    .font(.headline)
                    .foregroundStyle(.purple)
                Text("Plan Execution")
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                if !orchestrator.activePlan.isEmpty {
                    Button("Clear") {
                        withAnimation {
                            orchestrator.activePlan = []
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()
            
            if orchestrator.activePlan.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checklist.unchecked")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No Active Plan")
                        .font(.system(size: 13, weight: .semibold))
                    Text("The agent will outline its plan here when executing complex goals.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(orchestrator.activePlan.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 12) {
                                statusIcon(for: step.status)
                                    .padding(.top, 2)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Step \(index + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(statusColor(for: step.status))
                                    Text(step.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(step.status == "completed" ? .secondary : .primary)
                                        .strikethrough(step.status == "completed")
                                        .lineLimit(3)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    @ViewBuilder
    private func statusIcon(for status: String) -> some View {
        switch status.lowercased() {
        case "running":
            ProgressView()
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))
        case "failed":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 14))
        default: // queued
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
        }
    }
    
    private func statusColor(for status: String) -> Color {
        switch status.lowercased() {
        case "running": return .purple
        case "completed": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}
