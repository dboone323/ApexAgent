import SwiftUI
import SwiftData

// MARK: - Create Bot Sheet

struct CreateBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(BotManager.self) private var bm
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var avatarName = "person.fill"
    @State private var selectedModelProvider: ModelProvider?
    @State private var ollamaModelBinding = ""
    @State private var restrictTools = false
    @State private var selectedToolNames: Set<String> = []
    @State private var restrictMCPServers = false
    @State private var selectedMCPServers: Set<String> = []

    private let avatarOptions: [String] = [
        "person.fill", "robot", "brain.head.profile", "gear",
        "wand.and.stars", "chart.bar.doc.horizontal", "magnifyingglass",
        "laptopcomputer", "figure.run", "dollarsign.circle",
        "doc.text.viewfinder", "lightbulb", "camera.viewfinder",
        "speaker.wave.2", "cart", "building.2", "tag", "bell",
        "heart", "gamecontroller",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Bot Name (e.g. Piper)", text: $name)
                        .accessibilityLabel("Bot Name")
                        .accessibilityIdentifier("botNameTextField")

                    TextField("Short Title / Role (e.g. Product Performance)", text: $title)
                        .accessibilityLabel("Bot Title")
                }

                Section("What should this Bot do?") {
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 100)
                        .accessibilityLabel("Bot Description")

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tips for a good Bot")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        VStack(alignment: .leading, spacing: 4) {
                            TipRow(icon: "target", text: "Give it one clear job or area of ownership")
                            TipRow(icon: "doc.text", text: "Describe how it should work in operational terms")
                            TipRow(icon: "checkmark.circle", text: "Add rules it should always follow (e.g. 'Never send without approval')")
                            TipRow(icon: "face.smiling", text: "Pick an avatar that fits its role")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                Section("Avatar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                        ForEach(avatarOptions, id: \.self) { symbol in
                            Button {
                                avatarName = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 18))
                                    .foregroundStyle(avatarName == symbol ? .white : AppTheme.Palette.accent)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        avatarName == symbol
                                            ? AnyShapeStyle(AppTheme.Palette.accent)
                                            : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .clipShape(Circle())
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 20)
                                            .stroke(avatarName == symbol ? Color.clear : Color(nsColor: .separatorColor), lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Model Override") {
                    Picker("Model Provider", selection: $selectedModelProvider) {
                        Text("Use Global Default").tag(nil as ModelProvider?)
                        ForEach(ModelProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider as ModelProvider?)
                        }
                    }

                    if selectedModelProvider == .localOllama {
                        TextField("Ollama Model", text: $ollamaModelBinding, prompt: Text("gemma4:12bmlx (global default)"))
                    }

                    Text("When set to Auto Model Picker or Global Default, tasks are automatically routed: Apple On-Device for standard context (<=4k), Cloud Gemini Flash for high-complexity/large context (>4k), and Local Ollama (gemma4:12bmlx) for offline fallback.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                BotCapabilityEditorSection(
                    restrictTools: $restrictTools,
                    selectedToolNames: $selectedToolNames,
                    restrictMCPServers: $restrictMCPServers,
                    selectedMCPServers: $selectedMCPServers
                )

                Section {
                    Button("Create Bot") {
                        createBot()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("saveBotButton")
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Create Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            resetForm()
        }
        .accessibilityIdentifier("createBotSheet")
    }

    private func resetForm() {
        name = ""
        title = ""
        descriptionText = ""
        avatarName = "person.fill"
        selectedModelProvider = nil
        ollamaModelBinding = ""
        restrictTools = false
        selectedToolNames = []
        restrictMCPServers = false
        selectedMCPServers = []
    }

    private func createBot() {
        let bot = bm.createBot(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarName: avatarName
        )
        bot.modelProvider = selectedModelProvider
        let trimmedOllama = ollamaModelBinding.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.ollamaModelOverride = trimmedOllama.isEmpty ? nil : trimmedOllama
        if restrictTools {
            bot.allowedToolNames = Array(selectedToolNames).sorted()
        } else {
            bot.allowedToolNames = []
        }
        if restrictMCPServers {
            bot.allowedMCPServers = Array(selectedMCPServers).sorted()
        } else {
            bot.allowedMCPServers = []
        }
        bm.saveBot(bot)
        bm.openConversation(with: bot)
        dismiss()
    }
}

// MARK: - Tip Row

struct TipRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(AppTheme.Palette.accent)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Edit Bot Sheet

struct EditBotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var bot: BotProfile
    @Environment(BotManager.self) private var bm

    @State private var name: String
    @State private var title: String
    @State private var descriptionText: String
    @State private var avatarName: String
    @State private var memory: String
    @State private var showingMemoryEditor = false
    @State private var selectedModelProvider: ModelProvider?
    @State private var ollamaModelBinding: String
    @State private var restrictTools: Bool
    @State private var selectedToolNames: Set<String>
    @State private var restrictMCPServers: Bool
    @State private var selectedMCPServers: Set<String>

    private let avatarOptions: [String] = [
        "person.fill", "robot", "brain.head.profile", "gear",
        "wand.and.stars", "chart.bar.doc.horizontal", "magnifyingglass",
        "laptopcomputer", "figure.run", "dollarsign.circle",
        "doc.text.viewfinder", "lightbulb", "camera.viewfinder",
        "speaker.wave.2", "cart", "building.2", "tag", "bell",
        "heart", "gamecontroller",
    ]

    init(bot: BotProfile) {
        self.bot = bot
        _name = State(initialValue: bot.name)
        _title = State(initialValue: bot.title)
        _descriptionText = State(initialValue: bot.descriptionText)
        _avatarName = State(initialValue: bot.avatarName)
        _memory = State(initialValue: bot.memory)
        _selectedModelProvider = State(initialValue: bot.modelProvider)
        _ollamaModelBinding = State(initialValue: bot.ollamaModelOverride ?? "")
        _restrictTools = State(initialValue: !bot.allowedToolNames.isEmpty)
        _selectedToolNames = State(initialValue: Set(bot.allowedToolNames))
        _restrictMCPServers = State(initialValue: !bot.allowedMCPServers.isEmpty)
        _selectedMCPServers = State(initialValue: Set(bot.allowedMCPServers))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Bot Name", text: $name)
                        .accessibilityLabel("Bot Name")
                    TextField("Short Title / Role", text: $title)
                        .accessibilityLabel("Bot Title")
                }

                Section("What should this Bot do?") {
                    TextEditor(text: $descriptionText)
                        .frame(minHeight: 80)
                }

                Section("Durable Memory") {
                    Button {
                        showingMemoryEditor = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory & Preferences")
                                .font(.system(size: 13, weight: .medium))
                            if memory.isEmpty {
                                Text("No durable memory yet. Add facts, style preferences, and rules this Bot should remember across conversations.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("✻ \(memory.count) characters stored")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Text("Memory persists across conversations. Use it for style, format rules, and accumulated context — not as a substitute for checking current data.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Section("Avatar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                        ForEach(avatarOptions, id: \.self) { symbol in
                            Button {
                                avatarName = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 18))
                                    .foregroundStyle(avatarName == symbol ? .white : AppTheme.Palette.accent)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        avatarName == symbol
                                            ? AnyShapeStyle(AppTheme.Palette.accent)
                                            : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                                    )
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section("Model Override") {
                    Picker("Model Provider", selection: $selectedModelProvider) {
                        Text("Use Global Default").tag(nil as ModelProvider?)
                        ForEach(ModelProvider.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider as ModelProvider?)
                        }
                    }

                    if selectedModelProvider == .localOllama {
                        TextField("Ollama Model", text: $ollamaModelBinding, prompt: Text("gemma4:12bmlx (global default)"))
                    }

                    Text("When set to Auto Model Picker or Global Default, tasks are automatically routed: Apple On-Device for standard context (<=4k), Cloud Gemini Flash for high-complexity/large context (>4k), and Local Ollama (gemma4:12bmlx) for offline fallback.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                BotCapabilityEditorSection(
                    restrictTools: $restrictTools,
                    selectedToolNames: $selectedToolNames,
                    restrictMCPServers: $restrictMCPServers,
                    selectedMCPServers: $selectedMCPServers
                )

                Section {
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Edit Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingMemoryEditor) {
                MemoryEditorSheet(memory: $memory)
            }
        }
    }

    private func saveChanges() {
        bm.editBot(
            bot,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionText: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarName: avatarName,
            memory: memory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        bot.modelProvider = selectedModelProvider
        let trimmedOllama = ollamaModelBinding.trimmingCharacters(in: .whitespacesAndNewlines)
        bot.ollamaModelOverride = trimmedOllama.isEmpty ? nil : trimmedOllama
        if restrictTools {
            bot.allowedToolNames = Array(selectedToolNames).sorted()
        } else {
            bot.allowedToolNames = []
        }
        if restrictMCPServers {
            bot.allowedMCPServers = Array(selectedMCPServers).sorted()
        } else {
            bot.allowedMCPServers = []
        }
        bm.saveBot(bot)
        dismiss()
    }
}

// MARK: - Memory Editor Sheet

struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var memory: String
    @State private var draftMemory: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Add durable memory and preferences for this Bot.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                TextEditor(text: $draftMemory)
                    .frame(minHeight: 200)
                    .padding(8)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )

                Text("Examples: \"Always format reports as 5 bullets with source links. Never contact customers without approval. Prefer Python over Shell for data tasks.\"")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)

                Button("Save & Close") {
                    memory = draftMemory
                    dismiss()
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .navigationTitle("Durable Memory")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftMemory = memory
            }
        }
    }
}
// MARK: - Bot Capability & Tool Categories

struct ToolCategory: Identifiable {
    let id: String
    let name: String
    let icon: String
    let description: String
    let toolNames: [String]
}

enum BotCapabilityPresets {
    static let categories: [ToolCategory] = [
        ToolCategory(
            id: "fs_code",
            name: "Filesystem & Code",
            icon: "folder.badge.gearshape",
            description: "Read, write, patch files, list directories, and run git commands",
            toolNames: ["read_file", "write_file", "patch_file", "list_directory", "file_search", "git_operation", "verify_execution"]
        ),
        ToolCategory(
            id: "system_shell",
            name: "Terminal & Automation",
            icon: "terminal",
            description: "Execute shell commands, AppleScript, check system info, send notifications",
            toolNames: ["run_shell_command", "apple_script", "system_info", "send_notification"]
        ),
        ToolCategory(
            id: "web_search",
            name: "Web & Research",
            icon: "globe",
            description: "Search web, fetch web content, and inspect web pages",
            toolNames: ["web_search", "fetch_web_content", "control_browser"]
        ),
        ToolCategory(
            id: "memory_plan",
            name: "Memory & Planning",
            icon: "brain.head.profile",
            description: "Query and store durable bot memories, manage task execution plans",
            toolNames: ["search_memory", "store_memory", "update_plan"]
        ),
        ToolCategory(
            id: "collaboration",
            name: "Multi-Agent Collaboration",
            icon: "person.2",
            description: "Delegate tasks to other bots, ask teammates, convene meetings, dispatch swarms",
            toolNames: ["ask_bot", "delegate_task", "convene_meeting", "dispatch_swarm"]
        )
    ]

    static let readOnlyTools: Set<String> = [
        "read_file", "list_directory", "file_search", "web_search", "fetch_web_content", "search_memory"
    ]

    static let developerTools: Set<String> = [
        "read_file", "write_file", "patch_file", "list_directory", "file_search", "git_operation", "run_shell_command", "system_info"
    ]
}

// MARK: - Bot Capability Editor Section

struct BotCapabilityEditorSection: View {
    @Binding var restrictTools: Bool
    @Binding var selectedToolNames: Set<String>
    @Binding var restrictMCPServers: Bool
    @Binding var selectedMCPServers: Set<String>

    var body: some View {
        Section("Tool Permissions & Capabilities") {
            Toggle("Restrict Bot Tool Access", isOn: $restrictTools)
                .help("When disabled, the bot has access to all standard tools. When enabled, only selected capabilities are permitted.")

            if restrictTools {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Presets:")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Button("Read-Only") {
                            selectedToolNames = BotCapabilityPresets.readOnlyTools
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Developer") {
                            selectedToolNames = BotCapabilityPresets.developerTools
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Select All") {
                            selectedToolNames = Set(BotCapabilityPresets.categories.flatMap { $0.toolNames })
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Clear") {
                            selectedToolNames.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    ForEach(BotCapabilityPresets.categories) { category in
                        let categoryAllSelected = category.toolNames.allSatisfy { selectedToolNames.contains($0) }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: category.icon)
                                    .frame(width: 16)
                                    .foregroundStyle(AppTheme.Palette.accent)
                                Text(category.name)
                                    .font(.system(size: 12, weight: .medium))
                                Spacer()
                                Button(categoryAllSelected ? "Deselect" : "Select") {
                                    if categoryAllSelected {
                                        for tool in category.toolNames { selectedToolNames.remove(tool) }
                                    } else {
                                        for tool in category.toolNames { selectedToolNames.insert(tool) }
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(.system(size: 11))
                            }

                            Text(category.description)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading, spacing: 4) {
                                ForEach(category.toolNames, id: \.self) { tool in
                                    Toggle(isOn: Binding(
                                        get: { selectedToolNames.contains(tool) },
                                        set: { isSelected in
                                            if isSelected {
                                                selectedToolNames.insert(tool)
                                            } else {
                                                selectedToolNames.remove(tool)
                                            }
                                        }
                                    )) {
                                        Text(tool)
                                            .font(.system(size: 11, design: .monospaced))
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.leading, 8)
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }

        let mcpServers = MCPManager.shared.servers
        if !mcpServers.isEmpty {
            Section("MCP Server Scoping") {
                Toggle("Restrict MCP Servers", isOn: $restrictMCPServers)
                    .help("When disabled, the bot can call tools from all configured MCP servers. When enabled, only checked servers are allowed.")

                if restrictMCPServers {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permit tools from only these MCP servers:")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)

                        ForEach(mcpServers, id: \.id) { server in
                            Toggle(isOn: Binding(
                                get: { selectedMCPServers.contains(server.name) || selectedMCPServers.contains(server.id.uuidString) },
                                set: { isSelected in
                                    if isSelected {
                                        selectedMCPServers.insert(server.name)
                                    } else {
                                        selectedMCPServers.remove(server.name)
                                        selectedMCPServers.remove(server.id.uuidString)
                                    }
                                }
                            )) {
                                HStack(spacing: 6) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(AppTheme.Palette.accent)
                                    Text(server.name)
                                        .font(.system(size: 12))
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
        }
    }
}

