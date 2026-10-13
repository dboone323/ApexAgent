import SwiftUI
import Speech
import AppKit

struct VoicePermissionStatus: View {
    @State private var status: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    @State private var checked = false

    var accessibilityLabelText: String {
        "Speech recognition permission: \(label)"
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 11))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voicePermissionStatus")
        .accessibilityLabel(accessibilityLabelText)
        .task {
            status = SFSpeechRecognizer.authorizationStatus()
            checked = true
        }
    }

    private var color: Color {
        if !checked { return .secondary }
        switch status {
        case .authorized: return .green
        case .denied, .restricted: return .red
        default: return .yellow
        }
    }

    private var label: String {
        if !checked { return "checking..." }
        switch status {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not set"
        @unknown default: return "unknown"
        }
    }
}

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
    @State private var tavilyAPIKey: String = ""
    @State private var geminiAPIKey: String = ""
    @State private var geminiSaveStatus = ""
    @State private var geminiModel: String = "gemini-3.8-flash"
    @State private var copilotModel: String = "gpt-4o"
    @State private var copilotToken: String = ""
    @State private var autoTieringStrategy: AutoTieringStrategy = .balanced
    @State private var ollamaHostURL: String = "http://localhost:11434"
    @State private var ollamaModel: String = "gemma4:12b"
    @State private var localInstructions: String = ""
    @State private var showingResetConfirm = false
    @State private var showingQuickModeConfirm = false
    @State private var pendingQuickModeAction: (() -> Void)?
    @State private var mcpManager = MCPManager.shared
    @State private var newServerName = ""
    @State private var newServerCommand = ""
    @State private var newServerArgs = ""
    @State private var braveSaveTask: Task<Void, Never>?
    @State private var tavilySaveTask: Task<Void, Never>?
    @State private var geminiSaveTask: Task<Void, Never>?
    @State private var ollamaURLSaveTask: Task<Void, Never>?
    @State private var sandboxStateDescription: String = "Stopped"
    @State private var isSandboxRunning: Bool = false
    @State private var isSandboxTransitioning: Bool = false
    @State private var sandboxPollTask: Task<Void, Never>?

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
    @AppStorage("apex.collaborativeServerPort") private var collaborativeServerPort: Int = 1340
    @AppStorage("apex.lanModeEnabled") private var lanModeEnabled: Bool = false
    @AppStorage("apex.collabToken") private var collabToken: String = ""
    @AppStorage("apex.multiAgentModeEnabled") private var multiAgentModeEnabled: Bool = false
    @AppStorage("apex.voiceLocale") private var voiceLocale: String = "en-US"
    @AppStorage("apex.voiceSpeechRate") private var voiceSpeechRate: Double = 0.52
    @AppStorage("apex.reasoningBudget") private var reasoningBudget: String = "moderate"
    @AppStorage("apex.maxResponseTokens") private var maxResponseTokens: Int = 4096
    @AppStorage("apex.autoApproveToolCalls") private var autoApproveToolCalls: Bool = false
    @State private var isDaemonInstalled: Bool = false
    @State private var proactiveScheduler = ProactiveScheduler.shared
    @State private var alwaysAllowKeys: [String] = []
    @State private var isLoaded: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                modelConfigSection
                reasoningSection
                apiCredentialsSection
                tieringStrategySection
                ollamaSection
                safetySection
                voiceSection
                containersSection
                permissionsSection
                collaborativeSection
                a2aSection
                cognitiveMemorySection
                enterpriseSecuritySection
                mcpSection
                daemonSection
                proactivitySection
                toolGovernanceSection
                instructionsSection
                quickModesSection
                conversationDataSection
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("settingsDoneButton")
                }
            }
            .onAppear {
                 braveAPIKey = KeychainManager.get(key: "braveSearchAPIKey") ?? ""
                 tavilyAPIKey = KeychainManager.get(key: "tavilyAPIKey") ?? ""
                 geminiAPIKey = ModelRegistry.geminiAPIKey()
                 autoTieringStrategy = ModelRegistry.activeTieringStrategy()
                 geminiModel = ModelRegistry.geminiModel()
                 copilotModel = ModelRegistry.copilotModel()
                 copilotToken = ModelRegistry.copilotToken()
                 ollamaHostURL = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
                 ollamaModel = UserDefaults.standard.string(forKey: "apex.ollamaModel") ?? "gemma4:12b"
                 localInstructions = orchestrator.agentInstructions
                 orchestrator.multiAgentModeEnabled = multiAgentModeEnabled
                 startSandboxStatusPolling()
                 refreshDaemonStatus()
                 refreshAlwaysAllowKeys()
                 isLoaded = true
            }
            .onDisappear {
                 sandboxPollTask?.cancel()
            }
            .frame(minWidth: 480, minHeight: 520)
            .accessibilityIdentifier("settingsForm")
            .confirmationDialog("Change Agent Mode?", isPresented: $showingQuickModeConfirm, titleVisibility: .visible) {
                Button("Change Mode", role: .destructive) {
                    pendingQuickModeAction?()
                }
            } message: {
                Text("This will overwrite the current system prompt instructions and reset the model session.")
            }
        }
    }

    // MARK: - Subsections

    @ViewBuilder
    private var modelConfigSection: some View {
        Section("Model Configuration") {
            @Bindable var orch = orchestrator

            Picker("Model Provider", selection: $orch.modelPreference) {
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
    }

    @ViewBuilder
    private var reasoningSection: some View {
        Section("Reasoning & Output") {
            Picker("Reasoning Budget", selection: $reasoningBudget) {
                Text("Off").tag("off")
                Text("Light").tag("light")
                Text("Moderate").tag("moderate")
                Text("Deep").tag("deep")
            }
            .pickerStyle(.menu)
            .help("Controls on-device/PCC reasoning effort via the native DynamicProfile .reasoningLevel modifier.")

            Stepper("Max Response Tokens: \(maxResponseTokens)", value: $maxResponseTokens, in: 256...32768, step: 256)
                .help("Caps generated tokens via the native DynamicProfile .maximumResponseTokens modifier.")
        }
    }

    @ViewBuilder
    private var apiCredentialsSection: some View {
        Section("API Credentials (Keychain)") {
            SecureField("Brave Search API Key", text: $braveAPIKey)
                .font(AppTheme.Font.mono(13))
                .accessibilityLabel("Brave Search API Key")
                .onChange(of: braveAPIKey) {
                    guard isLoaded else { return }
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

            SecureField("Tavily Search API Key", text: $tavilyAPIKey)
                .font(AppTheme.Font.mono(13))
                .accessibilityLabel("Tavily Search API Key")
                .onChange(of: tavilyAPIKey) {
                    guard isLoaded else { return }
                    tavilySaveTask?.cancel()
                    tavilySaveTask = Task {
                        try? await Task.sleep(for: .seconds(0.5))
                        guard !Task.isCancelled else { return }
                        KeychainManager.save(key: "tavilyAPIKey", value: tavilyAPIKey)
                    }
                }
                .onSubmit {
                    tavilySaveTask?.cancel()
                    KeychainManager.save(key: "tavilyAPIKey", value: tavilyAPIKey)
                }

            SecureField("Gemini API Key", text: $geminiAPIKey)
                .font(AppTheme.Font.mono(13))
                .accessibilityLabel("Gemini API Key")
                .onChange(of: geminiAPIKey) {
                    guard isLoaded else { return }
                    geminiSaveTask?.cancel()
                    geminiSaveTask = Task {
                        try? await Task.sleep(for: .seconds(0.5))
                        guard !Task.isCancelled else { return }
                        geminiSaveStatus = ModelRegistry.saveGeminiAPIKey(geminiAPIKey)
                            ? "Gemini API key saved to Keychain."
                            : "Gemini API key could not be saved to Keychain."
                    }
                }
                .onSubmit {
                    geminiSaveTask?.cancel()
                    geminiSaveStatus = ModelRegistry.saveGeminiAPIKey(geminiAPIKey)
                        ? "Gemini API key saved to Keychain."
                        : "Gemini API key could not be saved to Keychain."
                }
            if !geminiSaveStatus.isEmpty {
                Text(geminiSaveStatus)
                    .font(.caption)
                    .foregroundStyle(geminiSaveStatus.contains("could not") ? .red : .secondary)
                    .accessibilityIdentifier("geminiKeySaveStatus")
            }

            Picker("Gemini Model", selection: $geminiModel) {
                ForEach(ModelRegistry.supportedGeminiModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .onChange(of: geminiModel) {
                ModelRegistry.setGeminiModel(geminiModel)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
                Text("API keys are stored in the macOS Keychain. Supports gemini-3.8-flash and gemini-3.1-pro.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }

        Section("🐙 GitHub Copilot") {
            Picker("Copilot Model", selection: $copilotModel) {
                ForEach(ModelRegistry.supportedCopilotModels, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .onChange(of: copilotModel) {
                ModelRegistry.setCopilotModel(copilotModel)
            }

            SecureField("GitHub Token (optional override)", text: $copilotToken)
                .font(AppTheme.Font.mono(13))
                .onChange(of: copilotToken) {
                    ModelRegistry.setCopilotToken(copilotToken)
                }

            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("Automatically detects active gh CLI login or GitHub Keychain credentials.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var tieringStrategySection: some View {
        Section("Auto Model Tiering & Balance") {
            Picker("Routing Strategy", selection: $autoTieringStrategy) {
                ForEach(AutoTieringStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .accessibilityLabel("Routing Strategy")
            .onChange(of: autoTieringStrategy) {
                UserDefaults.standard.set(autoTieringStrategy.rawValue, forKey: ModelRegistry.tieringStrategyKey)
            }

            Text(tieringStrategyDescription)
                .font(AppTheme.Font.caption(11))
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
    }

    @ViewBuilder
    private var ollamaSection: some View {
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
    }

    @ViewBuilder
    private var safetySection: some View {
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
    }

    @ViewBuilder
    private var voiceSection: some View {
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

                HStack {
                    Label("Voice Permissions", systemImage: "mic.fill")
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    Spacer()
                    VoicePermissionStatus()
                        .font(AppTheme.Font.caption(11))
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var containersSection: some View {
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
                                if let manager = ContainerBridge.shared {
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
                                if let manager = ContainerBridge.shared {
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
    }

    @ViewBuilder
    private var permissionsSection: some View {
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
    }

    @ViewBuilder
    private var collaborativeSection: some View {
        Section("Team Collaboration Server") {
            CollaborativeServerSettingsSection()
        }
    }

    @ViewBuilder
    private var a2aSection: some View {
        Section("A2A Interoperability") {
            A2ASettingsSection()
        }
    }

    @ViewBuilder
    private var cognitiveMemorySection: some View {
        Section("Cognitive Memory & Knowledge Graph") {
            CognitiveMemorySettingsSection()
        }
    }

    @ViewBuilder
    private var enterpriseSecuritySection: some View {
        Section("Enterprise Security & Virtualization") {
            EnterpriseSecuritySettingsSection()
        }
    }

    @ViewBuilder
    private var mcpSection: some View {
        Section("Model Context Protocol (MCP) Servers") {
            DynamicToolboxManagerSection()
            RoutinesSection()
        }

        SkillsSection()

        Section("Add New MCP Server") {
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
    }

    @ViewBuilder
    private var daemonSection: some View {
        Section("24/7 Background Daemon & Webhooks") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Supervised LaunchAgent Daemon")
                            .font(AppTheme.Font.headline(13, weight: .semibold))
                        Text(isDaemonInstalled ? "Daemon is installed & supervised by launchd." : "Daemon is not installed.")
                            .font(AppTheme.Font.caption(11))
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                    Spacer()
                    Button(isDaemonInstalled ? "Uninstall Daemon" : "Install Daemon") {
                        toggleDaemon()
                    }
                    .buttonStyle(.bordered)
                    .tint(isDaemonInstalled ? .red : .green)
                }
                
                Divider()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Webhook Ingress Endpoint")
                        .font(AppTheme.Font.headline(12, weight: .semibold))
                    Text("http://localhost:8800/hooks/<endpointId>")
                        .font(AppTheme.Font.mono(11))
                        .foregroundStyle(AppTheme.Palette.accent)
                    Text("Authorization: Bearer <secret> or header x-apex-secret: <secret>")
                        .font(AppTheme.Font.caption(10))
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var proactivitySection: some View {
        Section("Autonomous Bot Proactivity") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Autonomous Handoff & Confirmation Monitoring", isOn: $proactiveScheduler.isEnabled)
                    .font(AppTheme.Font.headline(13, weight: .semibold))

                Text("Proactively monitors stalled bot handoffs, unresolved approval gates, and routine execution errors to nudge teammates and prevent blocked workflows.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                if proactiveScheduler.isEnabled {
                    HStack {
                        Text("Active Proactive Findings: \(proactiveScheduler.activeFindings.count)")
                            .font(AppTheme.Font.caption(11))
                            .foregroundStyle(proactiveScheduler.activeFindings.isEmpty ? AppTheme.Palette.textSecondary : Color.orange)
                        Spacer()
                        Button("Run Scan Now") {
                            Task { await proactiveScheduler.evaluateNow() }
                        }
                        .font(AppTheme.Font.caption(11))
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var toolGovernanceSection: some View {
        Section("Tool Governance & Auto-Approval") {
            Toggle("Auto-Approve Safe Tool Calls", isOn: $autoApproveToolCalls)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Global Tool Access (Kill Switches)")
                    .font(AppTheme.Font.headline(12, weight: .semibold))
                Text("Disable high-risk tools app-wide across all agents and automated routines.")
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                ForEach(["run_shell_command", "write_file", "delete_file", "run_applescript", "browser_automation", "computer_use", "create_skill"], id: \.self) { toolName in
                    HStack {
                        Text(toolName)
                            .font(AppTheme.Font.mono(11))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { ToolPolicy.shared.isGloballyAllowed(toolName) },
                            set: { allowed in
                                ToolPolicy.shared.setToolEnabled(toolName, enabled: allowed)
                            }
                        ))
                        .toggleStyle(.switch)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
            
            if !alwaysAllowKeys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Remembered 'Always Allow' Grants")
                        .font(AppTheme.Font.headline(12, weight: .semibold))
                    ForEach(alwaysAllowKeys, id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(AppTheme.Font.mono(11))
                            Spacer()
                            Button("Revoke") {
                                revokeKey(key)
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.vertical, AppTheme.Spacing.xs)
            }
        }
    }

    @ViewBuilder
    private var instructionsSection: some View {
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
    }

    @ViewBuilder
    private var quickModesSection: some View {
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
    }

    @ViewBuilder
    private var conversationDataSection: some View {
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

    private var tieringStrategyDescription: String {
        switch autoTieringStrategy {
        case .balanced:
            return "Balanced: On-device (0–3.2k tokens) -> Local Ollama (3.2k–32k tokens) -> Cloud Gemini (>32k tokens & Vision). Preserves Gemini API quota while preventing local resource exhaustion on massive tasks."
        case .cloudFirst:
            return "Performance First: On-device (0–3.2k tokens) -> Cloud Gemini (>3.2k tokens & Vision) -> Ollama (offline fallback). Prioritizes maximum speed, uses cloud API quota."
        case .localFirst:
            return "Local First: On-device (0–3.2k tokens) -> Local Ollama (>3.2k tokens). Keeps all tasks strictly local."
        }
    }

    private var modelPrivacyText: String {
        switch orchestrator.modelPreference {
        case .autoPicker: return "Auto (Native AFM 3 → Cloud Gemini Flash → Local Ollama)"
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
        case .autoPicker: return "sparkles"
        case .localSystem: return "lock.shield"
        case .privateCloud: return "lock.icloud"
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
    // Default 1340: the daemon-mode ApexGatewayServer binds 1337
    // (AUDIT_2026-09-28 §3.2.19) — sharing the port caused silent bind failures.
    @AppStorage("apex.collaborativeServerPort") private var collaborativeServerPort: Int = 1340
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
        let logFileURL = ApexAgentStoragePaths.collaborationLogs.appendingPathComponent("collab-access.log")
        if fm.fileExists(atPath: logFileURL.path) {
            NSWorkspace.shared.open(logFileURL)
        }
    }

    @ViewBuilder
    var body: some View {
        Toggle(isOn: $collaborativeServerEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Collaborative Server")
                Text("Allow authorized team members and agents on your local network to collaborate.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .onChange(of: collaborativeServerEnabled) { _, newValue in
            if newValue {
                CollaborativeServer.shared.start(port: UInt16(collaborativeServerPort))
            } else {
                CollaborativeServer.shared.stop()
            }
        }

        if collaborativeServerEnabled {
            HStack {
                Text("Server Port")
                Spacer()
                TextField("Port", value: $collaborativeServerPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .onChange(of: collaborativeServerPort) { _, newPort in
                        if collaborativeServerEnabled {
                            CollaborativeServer.shared.stop()
                            CollaborativeServer.shared.start(port: UInt16(newPort))
                        }
                    }
            }

            Toggle(isOn: $lanModeEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require Authentication Token (LAN Mode)")
                    Text("Only clients presenting the secret token can connect.")
                        .font(AppTheme.Font.caption(11))
                        .foregroundStyle(AppTheme.Palette.textSecondary)
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
                if let manager = ContainerBridge.shared {
                    let desc = manager.stateDescription
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

    @MainActor
    fileprivate func refreshDaemonStatus() {
        let controller = LaunchAgentController()
        self.isDaemonInstalled = controller.isInstalled
    }

    @MainActor
    fileprivate func refreshAlwaysAllowKeys() {
        self.alwaysAllowKeys = UserDefaults.standard.stringArray(forKey: "apex.alwaysAllowKeys") ?? []
    }

    @MainActor
    fileprivate func toggleDaemon() {
        let controller = LaunchAgentController()
        if isDaemonInstalled {
            controller.bootoutNow()
            _ = try? controller.uninstall()
        } else {
            let appPath = Bundle.main.bundlePath
            let execPath = Bundle.main.executablePath ?? "\(appPath)/Contents/MacOS/ApexAgent"
            _ = try? controller.install(programPath: execPath)
            controller.bootstrapNow()
        }
        refreshDaemonStatus()
    }

    @MainActor
    fileprivate func revokeKey(_ key: String) {
        var keys = UserDefaults.standard.stringArray(forKey: "apex.alwaysAllowKeys") ?? []
        keys.removeAll { $0 == key }
        UserDefaults.standard.set(keys, forKey: "apex.alwaysAllowKeys")
        refreshAlwaysAllowKeys()
    }
}

struct A2ASettingsSection: View {
    @AppStorage("apex.a2aServerEnabled") private var a2aServerEnabled: Bool = false
    @AppStorage("apex.a2aDiscoveryEnabled") private var a2aDiscoveryEnabled: Bool = false
    @State private var discoveredCount = 0

    var body: some View {
        Toggle(isOn: $a2aServerEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable A2A Server (port 1338)")
                Text("Allows other agents to connect to this instance via Agent-to-Agent protocol.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .onChange(of: a2aServerEnabled) { _, newValue in
            if newValue {
                try? A2AServer.shared.start()
            } else {
                A2AServer.shared.stop()
            }
        }
        
        Toggle(isOn: $a2aDiscoveryEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable Peer Discovery (Bonjour)")
                Text("Discover other A2A-capable agents on the local network.")
                    .font(AppTheme.Font.caption(11))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .onChange(of: a2aDiscoveryEnabled) { _, newValue in
            if newValue {
                let serviceName = "ApexAgent-\(UUID().uuidString.prefix(4))"
                try? A2APeerDiscovery.shared.startDiscovery(serviceName: serviceName)
            } else {
                A2APeerDiscovery.shared.stopDiscovery()
            }
        }
        
        if a2aDiscoveryEnabled {
            Text("\(discoveredCount) peers found")
                .font(AppTheme.Font.caption(11))
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .onAppear { discoveredCount = A2APeerDiscovery.shared.discoveredPeers.count }
                .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                    discoveredCount = A2APeerDiscovery.shared.discoveredPeers.count
                }
        }
    }
}

// MARK: - Cognitive Memory Settings Section

struct CognitiveMemorySettingsSection: View {
    @AppStorage("apex.memory.episodicEnabled") private var episodicEnabled: Bool = true
    @AppStorage("apex.memory.compactionThreshold") private var compactionThreshold: Int = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Episodic Memory Recording", isOn: $episodicEnabled)
                .font(AppTheme.Font.headline(12, weight: .semibold))
            
            Text("Persists timestamped events, summaries, and agent interactions across sessions in ~/.apex/memory.")
                .font(AppTheme.Font.caption(11))
                .foregroundStyle(AppTheme.Palette.textSecondary)

            Stepper("Auto-compaction turn threshold: \(compactionThreshold)", value: $compactionThreshold, in: 8...64, step: 4)
                .font(AppTheme.Font.caption(11))

            HStack {
                Text("Storage Location: ~/.apex/memory/")
                    .font(AppTheme.Font.mono(11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Folder") {
                    let url = ApexAgentStoragePaths.directory("memory")
                    if !FileManager.default.fileExists(atPath: url.path) {
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    }
                    NSWorkspace.shared.open(url)
                }
                .font(AppTheme.Font.caption(11))
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}

// MARK: - Enterprise Security Settings Section

struct EnterpriseSecuritySettingsSection: View {
    @AppStorage("apex.security.strictContainerOnly") private var strictContainerOnly: Bool = false
    @AppStorage("apex.security.requireGrantForP2P") private var requireGrantForP2P: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Strict Isolation for External Scripts", isOn: $strictContainerOnly)
                .font(AppTheme.Font.headline(12, weight: .semibold))
            
            Text("Forces all bash scripts and MCP binary executions to run inside isolated micro-virtualized sandboxes.")
                .font(AppTheme.Font.caption(11))
                .foregroundStyle(AppTheme.Palette.textSecondary)

            Toggle("Enforce Peer-to-Peer Agent Authorization Grants", isOn: $requireGrantForP2P)
                .font(AppTheme.Font.headline(12, weight: .semibold))

            Text("Requires user approval before any bot can send dynamic @mentions or task handoffs to another bot.")
                .font(AppTheme.Font.caption(11))
                .foregroundStyle(AppTheme.Palette.textSecondary)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }
}
