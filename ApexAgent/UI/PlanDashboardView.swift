import SwiftUI
import Accessibility

struct PlanDashboardView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @State private var selectedStep: PlanStep?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(AppTheme.Palette.windowBackground)

            progressBar

            if orchestrator.activePlan.isEmpty {
                EmptyState(
                    icon: "checklist.unchecked",
                    title: "No Active Plan",
                    message: "The agent will outline its plan here when executing complex goals.",
                    actionTitle: nil,
                    action: nil
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(orchestrator.activePlan.enumerated()), id: \.offset) { index, step in
                            PlanStepRow(step: step, index: index) {
                                selectedStep = step
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 400)
        .background(AppTheme.Palette.windowBackground)
        .accessibilityIdentifier("planDashboard")
        .accessibilityLabel("Plan dashboard")
        .sheet(item: $selectedStep) { step in
            NavigationStack {
                PlanStepDetailView(step: step)
                    .navigationTitle("Step Details")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { selectedStep = nil } } }
            }
            .frame(width: 420, height: 280)
        }
        .onChange(of: orchestrator.activePlan.map { "\($0.title):\($0.status.rawValue)" }) { oldValue, newValue in
            if oldValue.count != newValue.count {
                let message = "Plan updated. Now contains \(newValue.count) steps."
                AccessibilityNotification.Announcement(message).post()
            } else {
                for (index, newStr) in newValue.enumerated() {
                    guard index < oldValue.count else { break }
                    let oldStr = oldValue[index]
                    if oldStr != newStr {
                        let step = orchestrator.activePlan[index]
                        let message = "Step \(index + 1) \(step.status == .completed ? "completed" : step.status == .running ? "is now running" : step.status == .failed ? "failed" : "updated"): \(step.title)"
                        AccessibilityNotification.Announcement(message).post()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "list.bullet.indent")
                .foregroundStyle(AppTheme.Palette.accent)
            Text("Plan Execution")
                .font(AppTheme.Font.headline())
                .foregroundStyle(AppTheme.Palette.textPrimary)
            Spacer()
            if !orchestrator.activePlan.isEmpty {
                Button("Clear") {
                    withAnimation { orchestrator.clearPlan() }
                }
                .font(AppTheme.Font.caption())
                .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }

    private var progressBar: some View {
        let total = orchestrator.activePlan.count
        let completed = orchestrator.activePlan.filter { $0.status == .completed }.count
        let fraction: Double = total > 0 ? Double(completed) / Double(total) : 0
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppTheme.Palette.controlBackground)
                Capsule()
                    .fill(AppTheme.Palette.accent)
                    .frame(width: proxy.size.width * fraction)
            }
            .frame(height: 4)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .frame(height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Execution progress")
        .accessibilityValue("\(completed) of \(total) steps completed")
    }
}
