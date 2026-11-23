//
//  AgentGovernanceView.swift
//  ApexAgent
//
//  Issue #181: Unified Agent Governance view (Agent 365-style):
//  identity, permissions, spend vs cap, and value in work completed in one place.
//

import SwiftUI

public struct AgentGovernanceView: View {
    @State private var agents: [AgentIdentityRecord] = []
    @State private var selectedAgentId: String?
    @State private var summaryText: String = ""
    @State private var showingAuditLog = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agent Governance")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Agent 365-style spend limits, work completed value, and authorization controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                // Free-tier badge
                HStack(spacing: 4) {
                    Image(systemName: "shield.checkered")
                        .foregroundStyle(.green)
                    Text("Free-Tier Guardrail Active")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12))
                .clipShape(Capsule())

                Button {
                    refreshData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh Governance Registry")
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Agent List & Governance Detail
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(agents) { agent in
                        AgentGovernanceCard(
                            agent: agent,
                            onStatusChanged: {
                                refreshData()
                            }
                        )
                    }

                    if agents.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.rectangle.stack")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No Agents Registered")
                                .font(.headline)
                            Text("Agents will appear here once registered with the governance system.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 40)
                    }
                }
                .padding()
            }
        }
        .onAppear {
            refreshData()
        }
    }

    private func refreshData() {
        let mgr = AgentGovernanceManager.shared
        agents = mgr.allAgents()
        summaryText = mgr.governanceSummaryView()
    }
}

// MARK: - Agent Governance Card

struct AgentGovernanceCard: View {
    let agent: AgentIdentityRecord
    var onStatusChanged: () -> Void

    var body: some View {
        let mgr = AgentGovernanceManager.shared
        let capRecord = mgr.spendLimit(for: "agent:\(agent.id)") ?? mgr.spendLimit(for: "global")
        let cap = capRecord?.spendLimit ?? 0.0
        let currentSpend = capRecord?.currentSpend ?? 0.0
        let values = mgr.valueAnalytics(for: agent.id)

        let totalTasks = values.reduce(0) { $0 + $1.tasksCompleted }
        let totalPRs = values.reduce(0) { $0 + $1.prsMerged }
        let totalVerified = values.reduce(0) { $0 + $1.verifiedRuns }
        let totalTokens = values.reduce(0) { $0 + $1.totalTokens }
        let totalCost = values.reduce(0.0) { $0 + $1.totalCost }

        VStack(alignment: .leading, spacing: 12) {
            // Identity Row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(agent.displayName)
                            .font(.headline)
                        Text("(\(agent.id))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Scope: \(agent.spaceId?.uuidString.prefix(8) ?? "Global")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Status Badge
                Text(agent.status.displayName.uppercased())
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(agent.status == .approved ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                    .foregroundStyle(agent.status == .approved ? Color.green : Color.red)
                    .clipShape(Capsule())

                // Action Button
                if agent.status == .approved {
                    Button("Block") {
                        mgr.blockAgent(id: agent.id, reason: "Blocked from UI", actor: "user")
                        onStatusChanged()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button("Approve") {
                        mgr.approveAgent(id: agent.id, reason: "Approved from UI", actor: "user")
                        onStatusChanged()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            Divider()

            // Permissions
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    ForEach(Array(agent.permissions).sorted(by: { $0.rawValue < $1.rawValue })) { perm in
                        Text(perm.rawValue)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            // Spend vs Cap
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Spend / Cap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", currentSpend)) / $\(String(format: "%.2f", cap))")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Status")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if cap > 0.0 && currentSpend >= cap {
                        Text("Hard Cap Exceeded")
                            .font(.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(.red)
                    } else if cap > 0.0 && (currentSpend / cap) >= 0.8 {
                        Text("Approaching Cap")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Free-Tier Safe")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.green)
                    }
                }
            }

            // Value in Work Completed (Not just tokens)
            VStack(alignment: .leading, spacing: 6) {
                Text("Work Completed (Value Record):")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {
                    ValueStat(title: "Tasks Done", value: "\(totalTasks)", icon: "checkmark.circle.fill", color: .blue)
                    ValueStat(title: "PRs Merged", value: "\(totalPRs)", icon: "arrow.triangle.merge", color: .purple)
                    ValueStat(title: "Verified Runs", value: "\(totalVerified)", icon: "star.fill", color: .orange)
                    ValueStat(title: "Tokens", value: "\(totalTokens)", icon: "number", color: .secondary)
                    ValueStat(title: "Cost", value: "$\(String(format: "%.4f", totalCost))", icon: "dollarsign.circle", color: .green)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

struct ValueStat: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.callout)
                .fontWeight(.bold)
        }
    }
}
