import SwiftUI

struct SettingsView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss
    @State private var braveAPIKey: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var ollamaHostURL: String = "http://localhost:11434"
    @State private var ollamaModel: String = "qwen2.5-coder:latest"
    @State private var localInstructions: String = ""
    @State private var showingResetConfirm = false
    @State private var mcpManager = MCPManager.shared
    @State private var newServerName = ""
    @State private var newServerCommand = ""
    @State private var newServerArgs = ""
    @AppStorage("apex.requireConfirmationAll") private var requireConfirmAll: Bool = false
    @AppStorage("apex.voiceModeEnabled") private var voiceModeEnabled: Bool = false
    @AppStorage("apex.dockerSandboxingEnabled") private var dockerSandboxingEnabled: Bool = false
    @AppStorage("apex.dockerImage") private var dockerImage: String = "swift:latest"
    @AppStorage("apex.collaborativeServerEnabled") private var collaborativeServerEnabled: Bool = false
    @AppStorage("apex.collaborativeServerPort") private var collaborativeServerPort: Int = 1337
    @AppStorage("apex.multiAgentModeEnabled") private var multiAgentModeEnabled: Bool = false

    var body: some View {
        NavigationStack {
            Form {

                // MARK: Model Status
                Section("Model Configuration") {
                    @Bindable var orchestrator = orchestrator

                    Picker("Model Provider", selection: $orchestrator.modelPreference) {
                        ForEach(AgentModelPreference.allCases) { preference in
                            Text(preference.rawValue).tag(preference)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: orchestrator.modelPreference) {
                        orchestrator.resetSession()
                    }

                    HStack {
                        Label("Availability Status", systemImage: "cpu")
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                        Spacer()
                        ModelStatusBadge()
                    }

                    HStack {
                        Label(modelPrivacyText, systemImage: modelPrivacyIcon)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.Palette.success)
                    }
                    .font(AppTheme.Font.body(12))
                }

                // MARK: API Keys
                Section("API Credentials (Keychain)") {
                    SecureField("Brave Search API Key", text: $braveAPIKey)
                        .font(AppTheme.Font.mono(13))
                        .onChange(of: braveAPIKey) {
                            KeychainManager.save(key: "braveSearchAPIKey", value: braveAPIKey)
                        }

                    SecureField("Gemini API Key", text: $geminiAPIKey)
                        .font(AppTheme.Font.mono(13))
                        .onChange(of: geminiAPIKey) {
                            KeychainManager.save(key: "geminiAPIKey", value: geminiAPIKey)
                        }

                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(AppTheme.Palette.textTertiary)
                        Text("API Keys are saved securely in your macOS Keychain.")
                            .font(AppTheme.Font.caption(11))
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }

                // MARK: Ollama Host
                Section("Ollama Settings") {
                    TextField("Ollama Host URL", text: $ollamaHostURL)
                        .font(AppTheme.Font.mono(13))
                        .autocorrectionDisabled()
                        .onChange(of: ollamaHostURL) {
                            UserDefaults.standard.set(ollamaHostURL, forKey: "apex.ollamaHostURL")
                        }

                    TextField("Ollama Model Name", text: $ollamaModel)
                        .font(AppTheme.Font.mono(13))
                        .autocorrectionDisabled()
                        .onChange(of: ollamaModel) {
                            UserDefaults.standard.set(ollamaModel, forKey: "apex.ollamaModel")
                        }
                }

                // MARK: Safety
                Section("Safety & Orchestration") {
                    Toggle(isOn: $requireConfirmAll) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirm all tool calls")
                            Text("Ask for approval before every tool execution (not just destructive ones)")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                    }
                    .onChange(of: requireConfirmAll) {
                        orchestrator.requireConfirmationForAll = requireConfirmAll
                    }

                    Toggle(isOn: $multiAgentModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Multi-Agent Collaboration")
                            Text("Apex Prime coordinates specialized Codex, Nexus, Pilot, Oracle, Auditor, Aura, and Chronos agents")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                    }
                    .onChange(of: multiAgentModeEnabled) {
                        orchestrator.multiAgentModeEnabled = multiAgentModeEnabled
                        orchestrator.resetSession()
                    }
                }

                // MARK: Voice Settings
                Section("Voice Settings") {
                    Toggle(isOn: $voiceModeEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Speak responses (Voice Mode)")
                            Text("Automatically speak the assistant's responses using system text-to-speech")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                    }
                }

                // MARK: Docker Sandboxing
                Section("Sandboxing & Isolation") {
                    Toggle(isOn: $dockerSandboxingEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Docker Sandboxing")
                            Text("Executes all terminal/shell operations inside a secure Docker container")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                    }

                    if dockerSandboxingEnabled {
                        TextField("Docker Image", text: $dockerImage)
                            .font(AppTheme.Font.mono(13))
                            .autocorrectionDisabled()
                    }
                }

                // MARK: System & Folder Permissions
                Section {
                    if let perms = orchestrator.permissions {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("System Access Checks")
                                .font(AppTheme.Font.headline(11, weight: .bold))
                                .foregroundStyle(AppTheme.Palette.textSecondary)

                            Toggle(isOn: Binding(
                                get: { perms.accessibilityAllowed },
                                set: { perms.accessibilityAllowed = $0; try? orchestrator.modelContext?.save() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Accessibility Entitlement Check")
                                    Text("Check and run GUI accessibility control tools.")
                                        .font(AppTheme.Font.caption(11))
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { perms.screenRecordingAllowed },
                                set: { perms.screenRecordingAllowed = $0; try? orchestrator.modelContext?.save() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Screen Recording Entitlement Check")
                                    Text("Check and allow screen capture capabilities.")
                                        .font(AppTheme.Font.caption(11))
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                }
                            }

                            Toggle(isOn: Binding(
                                get: { perms.systemAudioRecordingAllowed },
                                set: { perms.systemAudioRecordingAllowed = $0; try? orchestrator.modelContext?.save() }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("System Audio Recording")
                                    Text("Allow capturing microphone and system audio.")
                                        .font(AppTheme.Font.caption(11))
                                        .foregroundStyle(AppTheme.Palette.textSecondary)
                                }
                            }
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("User Folders Access")
                                .font(AppTheme.Font.headline(11, weight: .bold))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                                .padding(.top, 4)

                            Text("If any folder access is disabled, launched subprocesses will be sandboxed to prevent repeated OS TCC prompts.")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                                .padding(.bottom, 4)

                            Toggle("Music Folder (~/Music)", isOn: Binding(
                                get: { perms.musicFolderAllowed },
                                set: { perms.musicFolderAllowed = $0; try? orchestrator.modelContext?.save() }
                            ))

                            Toggle("Desktop Folder (~/Desktop)", isOn: Binding(
                                get: { perms.desktopFolderAllowed },
                                set: { perms.desktopFolderAllowed = $0; try? orchestrator.modelContext?.save() }
                            ))

                            Toggle("Documents Folder (~/Documents)", isOn: Binding(
                                get: { perms.documentsFolderAllowed },
                                set: { perms.documentsFolderAllowed = $0; try? orchestrator.modelContext?.save() }
                            ))

                            Toggle("Downloads Folder (~/Downloads)", isOn: Binding(
                                get: { perms.downloadsFolderAllowed },
                                set: { perms.downloadsFolderAllowed = $0; try? orchestrator.modelContext?.save() }
                            ))
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)
                    } else {
                        Text("Loading permissions...")
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                } header: {
                    Text("Permissions & Sandboxing")
                }


                // MARK: Collaborative Server
                Section("Team Collaboration Server") {
                    Toggle(isOn: $collaborativeServerEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Team Sharing Server")
                            Text("Broadcasts agent activity, plan status, and vision captures to local network")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                    }
                    .onChange(of: collaborativeServerEnabled) {
                        if collaborativeServerEnabled {
                            CollaborativeServer.shared.start(port: UInt16(collaborativeServerPort))
                        } else {
                            CollaborativeServer.shared.stop()
                        }
                    }

                    if collaborativeServerEnabled {
                        HStack {
                            Text("Sharing Port")
                            Spacer()
                            TextField("Port", value: $collaborativeServerPort, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }

                        Link(destination: URL(string: "http://localhost:\(collaborativeServerPort)")!) {
                            HStack {
                                Label("Open Collaboration Dashboard", systemImage: "safari")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 10))
                            }
                        }
                    }
                }

                // MARK: Model Context Protocol (MCP) Registry
                Section("Model Context Protocol (MCP) Servers") {
                    ForEach(mcpManager.servers) { config in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(config.name)
                                    .fontWeight(.medium)
                                Text("\(config.command) \(config.arguments.joined(separator: " "))")
                                    .font(AppTheme.Font.mono(10))
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                mcpManager.removeServer(id: config.id)
                                DynamicToolbox.shared.loadTools()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text("Add New MCP Server")
                            .font(AppTheme.Font.headline(11))
                            .bold()
                        TextField("Server Name (e.g. Postgres)", text: $newServerName)
                        TextField("Command (e.g. node, npx, python)", text: $newServerCommand)
                            .autocorrectionDisabled()
                        TextField("Arguments (space-separated)", text: $newServerArgs)
                            .autocorrectionDisabled()

                        Button("Add Server & Load Tools") {
                            let args = newServerArgs.split(separator: " ").map { String($0) }
                            let config = MCPServerConfig(name: newServerName, command: newServerCommand, arguments: args)
                            mcpManager.addServer(config)

                            newServerName = ""
                            newServerCommand = ""
                            newServerArgs = ""

                            DynamicToolbox.shared.loadTools()
                        }
                        .disabled(newServerName.isEmpty || newServerCommand.isEmpty)
                        .buttonStyle(.bordered)
                        .padding(.top, AppTheme.Spacing.sm)
                    }
                }

                // MARK: Sparkle Auto-Update
                Section("Application Updates") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-Updates (Sparkle)")
                            Text("Check for the latest version of Apex Agent")
                                .font(AppTheme.Font.caption(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                        Spacer()
                        Button("Check for Updates...") {
                            UpdaterController.shared.checkForUpdates()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // MARK: Agent Persona
                Section {
                    TextEditor(text: $localInstructions)
                        .font(AppTheme.Font.mono(12))
                        .frame(minHeight: 180)

                    HStack(spacing: AppTheme.Spacing.md) {
                        Button("Reset to Default") {
                            localInstructions = AgentSystemPrompt.default
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Apply") {
                            orchestrator.updateInstructions(localInstructions)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } header: {
                    Text("Agent Instructions (System Prompt)")
                } footer: {
                    Text("Changes take effect on the next new conversation.")
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }

                // MARK: Agent Modes
                Section("Quick Modes") {
                    ModeButton(
                        title: "💻 Coding Mode",
                        description: "Focused on software development and file editing",
                        color: .blue
                    ) {
                        localInstructions = AgentSystemPrompt.codingMode
                        orchestrator.updateInstructions(localInstructions)
                    }
                    ModeButton(
                        title: "🔍 Research Mode",
                        description: "Heavy web search and information synthesis",
                        color: .green
                    ) {
                        localInstructions = AgentSystemPrompt.researchMode
                        orchestrator.updateInstructions(localInstructions)
                    }
                    ModeButton(
                        title: "⚙️ System Mode",
                        description: "Full system access for admin tasks",
                        color: .orange
                    ) {
                        localInstructions = AgentSystemPrompt.systemMode
                        orchestrator.updateInstructions(localInstructions)
                    }
                }

                // MARK: Data
                Section("Conversation Data") {
                    Button(role: .destructive) {
                        showingResetConfirm = true
                    } label: {
                        Label("Clear Conversation History", systemImage: "trash")
                    }
                    .confirmationDialog("Clear all conversations?", isPresented: $showingResetConfirm, titleVisibility: .visible) {
                        Button("Clear All", role: .destructive) {
                            orchestrator.startNewConversation()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                braveAPIKey = KeychainManager.get(key: "braveSearchAPIKey") ?? ""
                geminiAPIKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
                ollamaHostURL = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
                ollamaModel = UserDefaults.standard.string(forKey: "apex.ollamaModel") ?? "qwen2.5-coder:latest"
                localInstructions = orchestrator.agentInstructions
                orchestrator.multiAgentModeEnabled = multiAgentModeEnabled
            }
            .frame(minWidth: 480, minHeight: 520)
        }
    }
    
    private var modelPrivacyText: String {
        switch orchestrator.modelPreference {
        case .localSystem: return "On-device (private, offline)"
        case .privateCloud: return "Apple Private Cloud Compute (encrypted)"
        case .cloudGemini: return "Google Gemini Cloud Service"
        case .localOllama: return "Local Ollama Service"
        case .hybrid: return "Hybrid (On-device & PCC fallback)"
        }
    }
    
    private var modelPrivacyIcon: String {
        switch orchestrator.modelPreference {
        case .localSystem: return "lock.shield"
        case .privateCloud: return "cloud.shield"
        case .cloudGemini: return "icloud"
        case .localOllama: return "cpu"
        case .hybrid: return "lock.icloud"
        }
    }
}

// MARK: - Mode Button

struct ModeButton: View {
    let title: String
    let description: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
