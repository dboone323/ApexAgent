import SwiftUI

// MARK: - Sub-Agent Manager View

/// A view that provides a manager/inbox overview of all active sub-agents.
/// Shows their status, results, and allows spawning new sub-agents.
@Observable
@MainActor
final class SubAgentManager: ObservableObject {
    var subAgents: [SubAgent.ID: SubAgent] = [:]

    var activeSubAgentIDs: [SubAgent.ID] {
        subAgents.keys.filter { subAgents[$0]?.status == .running }.map { $0 }
    }

    var completedSubAgentIDs: [SubAgent.ID] {
        subAgents.keys.filter { subAgents[$0]?.status == .completed }.map { $0 }
    }

    func updateSubAgents(from orchestrator: AgentOrchestrator) {
        subAgents = orchestrator.subAgents
    }

    func spawnSubAgent(type: AgentType, context: String = "") async -> SubAgent.ID {
        let id = SubAgent.ID()
        let agent = SubAgent(type: type, modelPreference: "autoPicker", budgetLimit: 15.0)
        subAgents[id] = agent
        // Fire and forget: run the sub-agent in the background
        Task { @MainActor in
            await AppDelegate.sharedOrchestrator.runSubAgent(id: id, type: type, context: context)
            subAgents[id] = AppDelegate.sharedOrchestrator.subAgents[id] ?? agent
        }
        return id
    }
}

// MARK: - Sub-Agent Manager View

struct SubAgentManagerView: View {
    @State private var manager = SubAgentManager()
    @State private var newAgentType: AgentType = .coder
    @State private var newContext: String = ""

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Summary stats
                HStack(spacing: 40) {
                    StatCard(
                        title: "Active",
                        count: manager.activeSubAgentIDs.count,
                        color: .green
                    )
                    StatCard(
                        title: "Completed",
                        count: manager.completedSubAgentIDs.count,
                        color: .blue
                    )
                }
                .padding(.horizontal)

                // Sub-agent list
                if manager.activeSubAgentIDs.isEmpty && manager.completedSubAgentIDs.isEmpty {
                    EmptyStateView()
                        .padding(.top, 40)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            // Active sub-agents
                            if !manager.activeSubAgentIDs.isEmpty {
                                Text("Active Sub-Agents")
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .foregroundStyle(.secondary)

                                ForEach(manager.activeSubAgentIDs, id: \.self) { id in
                                    SubAgentRow(agent: manager.subAgents[id]!)
                                }
                            }

                            // Completed sub-agents
                            if !manager.completedSubAgentIDs.isEmpty {
                                Text("Completed Sub-Agents")
                                    .font(.headline)
                                    .padding(.horizontal)
                                    .foregroundStyle(.secondary)

                                ForEach(manager.completedSubAgentIDs, id: \.self) { id in
                                    CompletedSubAgentRow(agent: manager.subAgents[id]!)
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                }

                // Spawn new sub-agent form
                Spacer()
                SpawnForm(manager: manager, type: $newAgentType, context: $newContext)
                    .padding(.horizontal)
                    .padding(.bottom, 20)
            }
            .navigationTitle("Sub-Agent Orchestration")
            .toolbar {
                ToolbarItem {
                    Button("Refresh") {
                        manager.updateSubAgents(from: AppDelegate.sharedOrchestrator)
                    }
                }
            }
            .task {
                manager.updateSubAgents(from: AppDelegate.sharedOrchestrator)
            }
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count)")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("No active sub-agents")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Spawn a new sub-agent to get started")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sub-Agent Row

struct SubAgentRow: View {
    let agent: SubAgent

    var statusColor: Color {
        switch agent.status {
        case .running: return .yellow
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .idle: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)

                Image(systemName: agentTypeIcon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(agentTypeName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("ID: \(agent.id.uuidString.prefix(8))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(agent.result ?? "Processing...")
                    .font(.footnote)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(statusColor.opacity(0.3))
                .frame(width: 8, height: 8)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .cornerRadius(12)
    }

    private var agentTypeIcon: String {
        switch agent.type {
        case .coder: return "function"
        case .reviewer: return "eye"
        case .browser: return "safari"
        case .researcher: return "magnifyingglass"
        default: return "circle"
        }
    }

    private var agentTypeName: String {
        switch agent.type {
        case .coder: return "Coder"
        case .reviewer: return "Reviewer"
        case .browser: return "Browser"
        case .researcher: return "Researcher"
        default: return "Agent"
        }
    }
}

// MARK: - Completed Sub-Agent Row

struct CompletedSubAgentRow: View {
    let agent: SubAgent

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 32, height: 32)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(agentTypeName(for: agent.type))
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(agent.result ?? "No result")
                    .font(.footnote)
                    .lineLimit(2)
            }

            Spacer()

            Text("\(agent.id.uuidString.prefix(8))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formatDate(agent.lastActivity))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func agentTypeName(for type: AgentType) -> String {
        switch type {
        case .coder: return "Coder"
        case .reviewer: return "Reviewer"
        case .browser: return "Browser"
        case .researcher: return "Researcher"
        default: return "Agent"
        }
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Spawn Form

struct SpawnForm: View {
    @ObservedObject var manager: SubAgentManager
    @Binding var type: AgentType
    @Binding var context: String

    var body: some View {
        VStack(spacing: 12) {
            Picker("Agent Type", selection: $type) {
                Text("Coder").tag(AgentType.coder)
                Text("Reviewer").tag(AgentType.reviewer)
                Text("Browser").tag(AgentType.browser)
                Text("Researcher").tag(AgentType.researcher)
            }
            .pickerStyle(.menu)
            .padding(.horizontal)

            TextField("Task context (optional)", text: $context)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)

            Button("Spawn Sub-Agent") {
                Task {
                    _ = await manager.spawnSubAgent(type: type, context: context)
                    // Could add notification or feedback here
                }
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
    }
}