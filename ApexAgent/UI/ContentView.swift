import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showActivityLog = true
    @State private var showTerminal = false
    @State private var showPlanDashboard = false
 
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Left sidebar: Conversation History
            List {
                if conversations.isEmpty {
                    ContentUnavailableView(
                        "No Chats Yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start a new conversation to begin.")
                    )
                    .labelsHidden()
                } else {
                    ForEach(conversations) { conversation in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                                    .font(.system(size: 13, weight: orchestrator.currentConversation?.id == conversation.id ? .semibold : .regular))
                                    .lineLimit(1)
                                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if orchestrator.currentConversation?.id == conversation.id {
                                Circle()
                                    .fill(Color.purple)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            orchestrator.loadConversation(conversation)
                        }
                    }
                    .onDelete(perform: deleteSavedConversations)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            .navigationTitle("Conversations")
        } detail: {
            // Main Content: Chat + Toggleable Tool Activity Sidebar
            HStack(spacing: 0) {
                VSplitView {
                    ChatView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: 200)
                    
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
        .navigationTitle("")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.purple)
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
 
                Button {
                    orchestrator.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Conversation (⌘N)")
 
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                
                Button {
                    showDiagnostics.toggle()
                } label: {
                    Image(systemName: "checklist")
                }
                .help("System Diagnostics Self-Check")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showTerminal.toggle()
                    }
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(showTerminal ? .purple : .primary)
                }
                .help("Toggle Terminal Console")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPlanDashboard.toggle()
                    }
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .foregroundStyle(showPlanDashboard ? .purple : .primary)
                }
                .help("Toggle Plan Dashboard")
                
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showActivityLog.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("Toggle Activity Log")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView()
        }
        .overlay {
            if let _ = orchestrator.pendingConfirmation {
                ConfirmationOverlay()
            }
        }
        .onAppear {
            orchestrator.modelContext = modelContext
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("showDiagnosticsSheet"))) { _ in
            showDiagnostics = true
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
        case .localSystem:
            return orchestrator.modelAvailability == .available ? "Local AFM 3" : "Model Offline"
        case .privateCloud:
            return "Apple PCC"
        case .cloudGemini:
            return "Gemini Cloud"
        case .localOllama:
            return "Ollama Local"
        case .hybrid:
            return "AFM 3 + PCC"
        }
    }
}
