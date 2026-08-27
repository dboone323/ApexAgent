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
    @State private var selectedModelProvider: ModelProvider? = nil
    @State private var ollamaModelBinding = ""

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

                    Text("When set to Apple On-Device or Global Default, tasks estimated over 4k tokens automatically tier to Private Cloud Compute, then Local Ollama (gemma4:12bmlx).")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Create Bot") {
                        createBot()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(name.isEmpty)
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
            .onAppear {
                if name.isEmpty {
                    name = generateBotName()
                }
            }
        }
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
        bm.openConversation(with: bot)
        dismiss()
    }

    private func generateBotName() -> String {
        let prefixes = ["Nova", "Apollo", "Atlas", "Orion", "Sage", "Raven", "Luna", "Echo", "Flux", "Pulse"]
        let suffixes = ["Bot", "Agent", "Assistant", "Helper", "Mate"]
        let p = prefixes.randomElement() ?? "Nova"
        let s = suffixes.randomElement() ?? "Bot"
        return "\(p) \(s)"
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
                                Text("✱ \(memory.count) characters stored")
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

                    Text("When set to Apple On-Device or Global Default, tasks estimated over 4k tokens automatically tier to Private Cloud Compute, then Local Ollama (gemma4:12bmlx).")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Save Changes") {
                        saveChanges()
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section {
                    Button(role: .destructive) {
                        dismiss()
                    } label: {
                        Text("Done (close sheet)")
                    }
                }
            }
            .navigationTitle("Edit Bot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
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
        dismiss()
    }
}

// MARK: - Memory Editor Sheet

struct MemoryEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var memory: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Add durable memory and preferences for this Bot.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                TextEditor(text: $memory)
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
        }
    }
}
