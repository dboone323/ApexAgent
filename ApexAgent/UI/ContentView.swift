import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Environment(BotManager.self) private var botManager
    @Environment(SpaceManager.self) private var spaceManager
    @Environment(Computer.self) private var computer
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @AppStorage("apex.showActivityLog") private var showActivityLog = true
    @AppStorage("apex.showTerminal") private var showTerminal = false
    @AppStorage("apex.showPlanDashboard") private var showPlanDashboard = false
    @State private var showCreateBotSheet = false
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // MARK: - Sidebar: Spaces + Bots + Conversations
            VStack(spacing: 0) {
                // Spaces section (Multi-Human + Multi-Agent rooms)
                SpacesSidebarSection(spaceManager: spaceManager)

                Divider().padding(.horizontal, 12)

                // Bots section (1:1 specialist sessions)
                BotSidebarSection(bm: botManager)
                
                Divider().padding(.horizontal, 12)

                // Routines section (Automated workflows & trigger schedules)
                RoutinesSidebarSection()

                Divider().padding(.horizontal, 12)
                
                // Conversations section (legacy)
                SidebarView(
                    conversations: conversations,
                    selectedConversation: orchestrator.currentConversation,
                    onSelectConversation: {
                        botManager.activeBotId = nil
                        spaceManager.activeSpaceId = nil
                        orchestrator.loadConversation($0)
                    },
                    onDeleteConversations: deleteSavedConversations
                )
                .frame(minHeight: 100)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 340)
            .navigationTitle("Apex Spaces & Bots")
        } detail: {
            // MARK: - Detail: Space Workspace / Bot Chat + Toggleable Sidebars
            VStack(spacing: 0) {
                AmbientApprovalSurfaceView()

                HStack(spacing: 0) {
                    VSplitView {
                    // Chat view (driven by active 1:1 Bot session, active Space channel, or legacy orchestrator)
                    if let session = botManager.activeSession {
                        BotChatView(session: session)
                            .id(session.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 200)
                    } else if spaceManager.activeSpaceId != nil && orchestrator.currentConversation == nil {
                        SpaceWorkspaceView(spaceManager: spaceManager)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 200)
                    } else {
                        ChatView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minHeight: 200)
                    }
                    
                    if showTerminal {
                        TerminalView()
                            .frame(maxWidth: .infinity)
                            .frame(height: 180)
                            .transition(.move(edge: .bottom))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                if showPlanDashboard {
                    Divider()
                    PlanDashboardView()
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
                
                if showActivityLog {
                    Divider()
                    ToolActivityView()
                        .frame(width: 280)
                        .transition(.move(edge: .trailing))
                }
            }
        }
    }
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(AppTheme.Palette.accent)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Apex")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    ModelStatusBadge()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                @Bindable var orchestrator = orchestrator
                
                Picker(selection: $orchestrator.toolCallingMode, label: Label("Tools", systemImage: "wrench.and.screwdriver")) {
                    ForEach(AgentToolCallingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .help("Tool Calling Mode")
                .accessibilityIdentifier("toolCallingModePicker")
                
                Button {
                    showCreateBotSheet = true
                } label: {
                    Image(systemName: "person.badge.plus")
                }
                .help("Create New Bot")
                .accessibilityIdentifier("createBotButton")
                
                Button {
                    botManager.activeBotId = nil
                    spaceManager.activeSpaceId = nil
                    orchestrator.startNewConversation()
                    NotificationCenter.default.post(name: NSNotification.Name("ApexAgent.focusChatInput"), object: nil)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Conversation (⌘N)")
                .accessibilityIdentifier("newConversationButton")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .foregroundStyle(columnVisibility == .all ? AppTheme.Palette.accent : .primary)
                }
                .focusable()
                .help("Toggle Sidebar")
                .accessibilityIdentifier("toggleSidebarButton")
                .accessibilityLabel("Toggle sidebar")
                
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .focusable()
                .help("Settings")
                .accessibilityIdentifier("settingsButton")
                .accessibilityLabel("Settings")
                
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: "checklist")
                }
                .focusable()
                .help("System Diagnostics Self-Check")
                .accessibilityIdentifier("diagnosticsButton")
                .accessibilityLabel("System diagnostics")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTerminal.toggle()
                    }
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(showTerminal ? AppTheme.Palette.accent : .primary)
                }
                .focusable()
                .help("Toggle Terminal Console")
                .accessibilityIdentifier("toggleTerminalButton")
                .accessibilityLabel("Toggle terminal console")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPlanDashboard.toggle()
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .foregroundStyle(showPlanDashboard ? AppTheme.Palette.accent : .primary)
                }
                .focusable()
                .help("Toggle Plan Dashboard")
                .accessibilityIdentifier("togglePlanDashboardButton")
                .accessibilityLabel("Toggle plan dashboard")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showActivityLog.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                        .foregroundStyle(showActivityLog ? AppTheme.Palette.accent : .primary)
                }
                .focusable()
                .help("Toggle Activity Log")
                .accessibilityIdentifier("toggleActivityLogButton")
                .accessibilityLabel("Toggle activity log")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(orchestrator)
                .environment(botManager)
                .environment(spaceManager)
                .environment(computer)
                .environment(\.skillManager, SkillManager.shared)
                .environment(SkillManager.shared)
                .environment(RoutineManager.shared)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .sheet(isPresented: $showCreateBotSheet) {
            CreateBotSheet()
        }
        .overlay {
            if let _ = orchestrator.pendingConfirmation {
                ConfirmationOverlay()
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                orchestrator.modelContext = modelContext
            }
            // Wire the BotManager's modelContext
            botManager.modelContext = modelContext
            botManager.reloadBots()
            // Wire SpaceManager's modelContext and load/seed Spaces
            spaceManager.orchestrator = orchestrator
            spaceManager.botManager = botManager
            spaceManager.modelContext = modelContext
            spaceManager.loadSpacesFromDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showDiagnosticsSheet)) { _ in
            showDiagnostics = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsSheet)) { _ in
            showSettings = true
        }
        .onChange(of: DeepLinkNavigationState.shared.activeChatId) { _, newChatId in
            guard let newChatId else { return }
            if let match = conversations.first(where: { $0.id.uuidString == newChatId }) {
                botManager.activeBotId = nil
                spaceManager.activeSpaceId = nil
                orchestrator.loadConversation(match)
            }
        }
        .task {
            while !Task.isCancelled {
                botManager.expireStalePeerApprovals()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
    
    private func deleteSavedConversations(at offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            orchestrator.deleteConversation(conversation)
        }
    }
}

// MARK: - Model Status Badge

struct ModelStatusBadge: View {
    @Environment(AgentOrchestrator.self) private var orchestrator

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
    }

    private var statusColor: Color {
        switch orchestrator.modelAvailability {
        case .available: return .green
        case .unavailable: return .red
        @unknown default: return .orange
        }
    }

    private var statusText: String {
        switch orchestrator.modelPreference {
        case .autoPicker:
            return "Auto (AFM → Gemini → Ollama)"
        case .localSystem:
            return orchestrator.modelAvailability == .available ? "Local AFM 3" : "Model Offline"
        case .privateCloud:
            return "Apple PCC"
        case .cloudGemini:
            return "Gemini Cloud"
        case .localOllama:
            return "Ollama Local"
        case .localMLX:
            return "MLX Local"
        case .hybrid:
            return "AFM 3 + PCC"
        }
    }
}

extension Notification.Name {
    public static let showDiagnosticsSheet = Notification.Name("showDiagnosticsSheet")
}
