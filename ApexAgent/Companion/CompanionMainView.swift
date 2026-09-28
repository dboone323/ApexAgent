import SwiftUI

// MARK: - Companion Main View (iPhone 15 Pro Max Host Control)

public struct CompanionMainView: View {
    @ObservedObject public var client: ApexCompanionMobileClient
    @ObservedObject public var gateway: RemoteCompanionGateway

    @State private var selectedTab: Int = 0
    @State private var isVoicePresented: Bool = false

    public init(client: ApexCompanionMobileClient, gateway: RemoteCompanionGateway) {
        self.client = client
        self.gateway = gateway
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Live Approvals Queue
            NavigationStack {
                approvalsView
                    .navigationTitle("Approvals")
            }
            .tabItem {
                Label("Approvals", systemImage: "checkmark.shield.fill")
            }
            .tag(0)
            .badge(gateway.pendingApprovalRelays.count)

            // Tab 2: Live Activity & Playbooks
            NavigationStack {
                liveActivityView
                    .navigationTitle("Playbooks")
            }
            .tabItem {
                Label("Playbooks", systemImage: "play.circle.fill")
            }
            .tag(1)

            // Tab 3: Talk & Sensors
            NavigationStack {
                sensorNodeView
                    .navigationTitle("Node Sensors")
            }
            .tabItem {
                Label("Sensors", systemImage: "camera.viewfinder")
            }
            .tag(2)
        }
        .sheet(isPresented: $isVoicePresented) {
            CompanionVoiceOrbView(
                isSpeaking: false,
                decibelLevel: -30.0,
                onDismiss: { isVoicePresented = false }
            )
        }
    }

    // MARK: - Subviews

    private var approvalsView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if gateway.pendingApprovalRelays.isEmpty {
                    ContentUnavailableView(
                        "No Pending Approvals",
                        systemImage: "checkmark.seal.fill",
                        description: Text("All bot tasks and playbook stages are running smoothly.")
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(Array(gateway.pendingApprovalRelays.values), id: \.requestId) { event in
                        CompanionApprovalCardView(event: event) { approved, notes in
                            _ = client.submitDecision(on: gateway, requestId: event.requestId, allow: approved, notes: notes)
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var liveActivityView: some View {
        VStack(spacing: 20) {
            if let activity = gateway.currentLiveActivity {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(activity.playbookTitle, systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        Text("Active")
                            .font(.caption.bold())
                            .foregroundStyle(.green)
                    }

                    Text("Stage: \(activity.currentStageTitle)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text("Active Bot: \(activity.activeBotName)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ProgressView(value: activity.progressFraction)
                        .tint(.accentColor)
                }
                .padding(16)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
            } else {
                ContentUnavailableView(
                    "No Active Playbook",
                    systemImage: "moon.stars.fill",
                    description: Text("Trigger a playbook on your Mac to stream live Dynamic Island progress.")
                )
            }
            Spacer()
        }
        .padding(.top, 20)
    }

    private var sensorNodeView: some View {
        VStack(spacing: 24) {
            Button {
                isVoicePresented = true
            } label: {
                Label("Open Full-Duplex Voice Talk", systemImage: "mic.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Hardware Sensor Status")
                    .font(.headline)

                HStack {
                    Image(systemName: "camera.fill")
                    Text("Camera Node")
                    Spacer()
                    Text("Ready")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)

                HStack {
                    Image(systemName: "location.fill")
                    Text("Location Node")
                    Spacer()
                    Text("Ready")
                        .foregroundStyle(.green)
                }
                .font(.subheadline)
            }
            .padding(16)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)

            Spacer()
        }
        .padding(.top, 20)
    }
}
