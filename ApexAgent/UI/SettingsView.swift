import SwiftUI

enum IsolationMode: String, CaseIterable, Identifiable {
    case none = "None"
    case appleContainer = "Apple Container"
    case docker = "Docker"
    
    var id: String { self.rawValue }
}

struct SettingsView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss
    @State private var braveAPIKey: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var geminiModel: String = "gemini-2.0-flash"
    @State private var ollamaHostURL: String = "http://localhost:11434"
    @State private var ollamaModel: String = "qwen2.5-coder:latest"
    @State private var localInstructions: String = ""
    @State private var showingResetConfirm = false
    @State private var showingQuickModeConfirm = false
    @State private var pendingQuickModeAction: (() -> Void)? = nil
    @State private var mcpManager = MCPManager.shared
    @State private var newServerName = ""
    @State private var newServerCommand = ""
    @State private var newServerArgs = ""
    @State private var braveSaveTask: Task<Void, Never>? = nil
    @State private var geminiSaveTask: Task<Void, Never>? = nil
    @State private var ollamaURLSaveTask: Task<Void, Never>? = nil
    @State private var sandboxStateDescription: String = "Stopped"
    @State private var isSandboxRunning: Bool = false
    @State private var isSandboxTransitioning: Bool = false
    @State private var sandboxPollTask: Task<Void, Never>? = nil

    private var isolationMode: Binding<IsolationMode> {
        Binding(
            get: {
                if appleContainersEnabled { return .appleContainer }
                if dockerSandboxingEnabled { return .docker }
                return .none
            },
            set: { newValue in
                switch newValue {
                case .none:
                    appleContainersEnabled = false
                    dockerSandboxingEnabled = false
                case .appleContainer:
                    appleContainersEnabled = true
                    dockerSandboxingEnabled = false
                case .docker:
                    appleContainersEnabled = false
                    dockerSandboxingEnabled = true
                }
            }
        )
    }
    @AppStorage("apex.requireConfirmationAll") private var requireConfirmAll: Bool = false
    @AppStorage("apex.voiceModeEnabled") private var voiceModeEnabled: Bool = false
    @AppStorage("apex.appleContainersEnabled") private var appleContainersEnabled: Bool = false
    @AppStorage("apex.appleContainerImage") private var appleContainerImage: String = "swift:latest"
    @AppStorage("apex.containerCPUs") private var containerCPUs: Int = 4
    @AppStorage("apex.containerMemoryMB") private var containerMemoryMB: Int = 1024
    @AppStorage("apex.dockerSandboxingEnabled") private var dockerSandboxingEnabled: Bool = false
    @AppStorage("apex.dockerImage") private var dockerImage: String = "swift:latest"
    @AppStorage("apex.collaborativeServerEnabled") private var collaborativeServerEnabled: Bool = false
    @AppStorage("apex.collaborativeServerPort") private var collaborativeServerPort: Int = 1337
    @AppStorage("apex.lanModeEnabled") private var lanModeEnabled: Bool = false
    @AppStorage("apex.collabToken") private var collabToken: String = ""
    @AppStorage("apex.multiAgentModeEnabled") private var multiAgentModeEnabled: Bool = false
    @AppStorage("apex.voiceLocale") private var voiceLocale: String = "en-US"
    @AppStorage("apex.voiceSpeechRate") private var voiceSpeechRate: Double = 0.52

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
                        .accessibilityLabel("Brave Search API Key")
                        .onChange(of: braveAPIKey) {
                            braveSaveTask?.cancel()
                            braveSaveTask = Task {
                                try? await Task.sleep(for: .seconds(0.5))
                                guard !Task.isCancelled else { return }
                                KeychainManager.save(key: "braveSearchAPIKey", value: braveAPIKey)
                            }
                        }
                        .onSubmit {
                            braveSaveTask?.cancel()
                            KeychainManager.save(key: "braveSearchAPIKey", value: braveAPIKey)
                        }

                    SecureField("Gemini API Key", text: $geminiAPIKey)
                        .font(AppTheme.Font.mono(13))
                        .accessibilityLabel("Gemini API Key")
                        .onChange(of: geminiAPIKey) {
                            geminiSaveTask?.cancel()
                            geminiSaveTask = Task {
                                try? await Task.sleep(for: .seconds(0.5))
                                guard !Task.isCancelled else { return }
                                KeychainManager.save(key: "geminiAPIKey", value: geminiAPIKey)
                            }
                        }
                        .onSubmit {
                            geminiSaveTask?.cancel()
                            KeychainManager.save(key: "geminiAPIKey", value: geminiAPIKey)
                        }

                    TextField("Gemini Model Name", text: $geminiModel)
                        .font(AppTheme.Font.mono(13))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Gemini Model Name")
                        .onChange(of: geminiModel) {
                            UserDefaults.standard.set(geminiModel, forKey: "apex.geminiModel")
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
                        .accessibilityLabel("Ollama Host URL")
                        .onChange(of: ollamaHostURL) {
                            ollamaURLSaveTask?.cancel()
                            ollamaURLSaveTask = Task {
                                try? await Task.sleep(for: .seconds(0.5))
                                guard !Task.isCancelled else { return }
                                UserDefaults.standard.set(ollamaHostURL, forKey: "apex.ollamaHostURL")
                            }
                        }
                        .onSubmit {
                            ollamaURLSaveTask?.cancel()
                            UserDefaults.standard.set(ollamaHostURL, forKey: "apex.ollamaHostURL")
                        }

                    TextField("Ollama Model Name", text: $ollamaModel)
                        .font(AppTheme.Font.mono(13))
                        .autocorrectionDisabled()
                        .accessibilityLabel("Ollama Model Name")
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

                    if voiceModeEnabled {
                        Picker("Voice Language", selection: $voiceLocale) {
                            Text("English (US)").tag("en-US")
                            Text("English (UK)").tag("en-GB")
                            Text("Spanish (Spain)").tag("es-ES")
                            Text("French (France)").tag("fr-FR")
                            Text("German (Germany)").tag("de-DE")
                            Text("Japanese (Japan)").tag("ja-JP")
                            Text("Chinese (China)").tag("zh-CN")
                        }
                        .pickerStyle(.menu)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Speech Rate")
                                Spacer()
                                Text(String(format: "%.2f", voiceSpeechRate))
                                    .font(AppTheme.Font.mono(11))
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                            Slider(value: $voiceSpeechRate, in: 0.1...1.0, step: 0.05)
                        }
                    }
                }

                // MARK: Sandboxing & Isolation
                Section("Sandboxing & Isolation") {
                    Picker("Sandbox Mode", selection: isolationMode) {
                        ForEach(IsolationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if appleContainersEnabled {
                        TextField("Apple Container Image", text: $appleContainerImage)
                            .font(AppTheme.Font.mono(13))
                            .autocorrectionDisabled()
                            .accessibilityLabel("Apple Container Image")
                        
                        Stepper("CPUs: \(containerCPUs)", value: $containerCPUs, in: 1...8)
                        
                        Stepper("Memory: \(containerMemoryMB) MB", value: $containerMemoryMB, in: 512...8192, step: 256)
                        
                        HStack {
                            Text("Sandbox: \(sandboxStateDescription)")
                                .font(AppTheme.Font.caption(11))
                                .foregroundColor(.secondary)
                            Spacer()
                            if isSandboxTransitioning {
                                ProgressView()
                                    .controlSize(.small)
                            } else if isSandboxRunning {
                                Button("Stop Sandbox") {
                                    Task {
                                        if let manager = await ContainerBridge.shared {
                                            try? await manager.stopContainer()
                                            startSandboxStatusPolling()
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            } else {
                                Button("Start Sandbox") {
                                    Task {
                                        if let manager = await ContainerBridge.shared {
                                            try? await manager.startContainer()
                                            startSandboxStatusPolling()
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .tint(.green)
                            }
                        }
                        .padding(.top, 4)
                    }

                    if dockerSandboxingEnabled {
                        TextField("Docker Image", text: $dockerImage)
                            .font(AppTheme.Font.mono(13))
                            .autocorrectionDisabled()
                            .accessibilityLabel("Docker Image")
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
                    CollaborativeServerSettingsSection()
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
                            .accessibilityLabel("New Server Name")
                        TextField("Command (e.g. node, npx, python)", text: $newServerCommand)
                            .autocorrectionDisabled()
                            .accessibilityLabel("New Server Command")
                        TextField("Arguments (space-separated)", text: $newServerArgs)
                            .autocorrectionDisabled()
                            .accessibilityLabel("New Server Arguments")

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
                        selectQuickMode(instructions: AgentSystemPrompt.codingMode)
                    }
                    ModeButton(
                        title: "🔍 Research Mode",
                        description: "Heavy web search and information synthesis",
                        color: .green
                    ) {
                        selectQuickMode(instructions: AgentSystemPrompt.researchMode)
                    }
                    ModeButton(
                        title: "⚙️ System Mode",
                        description: "Full system access for admin tasks",
                        color: .orange
                    ) {
                        selectQuickMode(instructions: AgentSystemPrompt.systemMode)
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
                            orchestrator.clearAllConversations()
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
                 geminiModel = UserDefaults.standard.string(forKey: "apex.geminiModel") ?? "gemini-2.0-flash"
                 ollamaHostURL = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
                 ollamaModel = UserDefaults.standard.string(forKey: "apex.ollamaModel") ?? "qwen2.5-coder:latest"
                 localInstructions = orchestrator.agentInstructions
                 orchestrator.multiAgentModeEnabled = multiAgentModeEnabled
                 startSandboxStatusPolling()
            }
            .onDisappear {
                 sandboxPollTask?.cancel()
            }
            .frame(minWidth: 480, minHeight: 520)
            .confirmationDialog("Change Agent Mode?", isPresented: $showingQuickModeConfirm, titleVisibility: .visible) {
                Button("Change Mode", role: .destructive) {
                    pendingQuickModeAction?()
                }
            } message: {
                Text("This will overwrite the current system prompt instructions and reset the model session.")
            }
        }
    }
    
    private var modelPrivacyText: String {
        switch orchestrator.modelPreference {
        case .localSystem: return "On-device (private, offline)"
        case .privateCloud: return "Apple Private Cloud Compute (encrypted)"
        case .cloudGemini: return "Google Gemini Cloud Service"
        case .localOllama: return "Local Ollama Service"
        case .localMLX: return "Local MLX-LM Server"
        case .hybrid: return "Hybrid (On-device & PCC fallback)"
        }
    }
    
    private var modelPrivacyIcon: String {
        switch orchestrator.modelPreference {
        case .localSystem: return "lock.shield"
        case .privateCloud: return "cloud.shield"
        case .cloudGemini: return "icloud"
        case .localOllama: return "cpu"
        case .localMLX: return "memorychip"
        case .hybrid: return "lock.icloud"
        }
    }



    private func selectQuickMode(instructions: String) {
        pendingQuickModeAction = {
            localInstructions = instructions
            orchestrator.updateInstructions(instructions)
        }
        showingQuickModeConfirm = true
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

struct CollaborativeServerSettingsSection: View {
    @AppStorage("apex.collaborativeServerEnabled") private var collaborativeServerEnabled: Bool = false
    @AppStorage("apex.collaborativeServerPort") private var collaborativeServerPort: Int = 1337
    @AppStorage("apex.lanModeEnabled") private var lanModeEnabled: Bool = false
    @AppStorage("apex.collabToken") private var collabToken: String = ""
    
    private var collaborativeServerURL: URL? {
        let serverURLString = lanModeEnabled 
            ? "http://localhost:\(collaborativeServerPort)/?token=\(collabToken)"
            : "http://localhost:\(collaborativeServerPort)"
        return URL(string: serverURLString)
    }

    private func openAccessAuditLog() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let logFileURL = homeDir.appendingPathComponent("Library/Logs/ApexAgent/collab-access.log")
        if fm.fileExists(atPath: logFileURL.path) {
            NSWorkspace.shared.open(logFileURL)
        }
    }

    @ViewBuilder
    var body: some View {
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
                    .accessibilityLabel("Sharing Port")
            }
            .onChange(of: collaborativeServerPort) { oldValue, newValue in
                if newValue < 1 {
                    collaborativeServerPort = 1337
                } else if newValue > 65535 {
                    collaborativeServerPort = 65535
                }
            }

            Toggle("Allow LAN Access", isOn: $lanModeEnabled)
                .onChange(of: lanModeEnabled) {
                    if collaborativeServerEnabled {
                        CollaborativeServer.shared.stop()
                        CollaborativeServer.shared.start(port: UInt16(collaborativeServerPort))
                    }
                }
            
            if lanModeEnabled {
                HStack {
                    Text("Auth Token")
                    Spacer()
                    Text(collabToken.isEmpty ? "None" : collabToken)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppTheme.Palette.textPrimary)
                        .contextMenu {
                            Button("Copy Token") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(collabToken, forType: .string)
                            }
                        }
                    
                    Button(action: {
                        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
                        collabToken = String(newToken)
                        if collaborativeServerEnabled {
                            CollaborativeServer.shared.stop()
                            CollaborativeServer.shared.start(port: UInt16(collaborativeServerPort))
                        }
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Regenerate Token")
                }
            }

            if let serverURL = collaborativeServerURL {
                Link(destination: serverURL) {
                    HStack {
                        Label("Open Collaboration Dashboard", systemImage: "safari")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                }
            }
            
            Button(action: openAccessAuditLog) {
                HStack {
                    Label("View Access Audit Log", systemImage: "doc.text.magnifyingglass")
                    Spacer()
                }
            }
        }
    }
}
    
extension SettingsView {
    @MainActor
    fileprivate func startSandboxStatusPolling() {
        sandboxPollTask?.cancel()
        sandboxPollTask = Task {
            while !Task.isCancelled {
                if let manager = await ContainerBridge.shared {
                    let desc = await manager.stateDescription
                    self.sandboxStateDescription = desc
                    self.isSandboxRunning = desc == "Sandbox Running"
                    self.isSandboxTransitioning = desc.contains("...") || desc.contains("Downloading") || desc.contains("Pulling")
                } else {
                    self.sandboxStateDescription = "Sandbox unavailable"
                    self.isSandboxRunning = false
                    self.isSandboxTransitioning = false
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
