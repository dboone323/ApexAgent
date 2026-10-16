import SwiftUI
import SwiftData
import AppKit
import FoundationModels
import UniformTypeIdentifiers

// MARK: - Bot Sidebar Section

struct BotSidebarSection: View {
    var bm: BotManager
    @State private var showEditSheet = false
    @State private var editingBot: BotProfile?
    @State private var showDeleteConfirm = false
    @State private var botToDelete: BotProfile?
    @State private var showImportURLAlert = false
    @State private var importURLString = ""
    @State private var playbookNotification: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.accent)
                Text("Bots")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer()
                Text("\(bm.allBots.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                
                // Playbook Actions Menu
                Menu {
                    Section("Run Playbook") {
                        ForEach(CollaborationPlaybook.builtInPresets) { preset in
                            Button {
                                runPlaybookPreset(preset)
                            } label: {
                                Label("Run \(preset.name)", systemImage: "play.circle")
                            }
                        }
                    }
                    Divider()
                    Section("Import / Export") {
                        Button {
                            exportPlaybookJSON()
                        } label: {
                            Label("Export Team Playbook (JSON)...", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            exportPlaybookMarkdown()
                        } label: {
                            Label("Export Team Playbook (Markdown)...", systemImage: "doc.text")
                        }
                        Button {
                            importPlaybookFromFile()
                        } label: {
                            Label("Import Playbook File...", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            importURLString = ""
                            showImportURLAlert = true
                        } label: {
                            Label("Import Playbook from URL...", systemImage: "link")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 16, height: 16)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            // Notification toast if playbook imported/exported
            if let note = playbookNotification {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Palette.accent)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }
            
            // Bot list
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(bm.allBots) { bot in
                        BotSidebarItem(
                            bot: bot,
                            isActive: bm.activeBotId == bot.id,
                            onSelect: {
                                bm.setActiveBot(bot.id)
                                bm.openConversation(with: bot)
                            },
                            onEdit: {
                                editingBot = bot
                                showEditSheet = true
                            },
                            onDelete: {
                                botToDelete = bot
                                showDeleteConfirm = true
                            },
                            onTogglePin: {
                                bm.togglePin(bot)
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            
            // Create button
            Button {
                editingBot = nil
                showEditSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 11))
                    Text("New Bot")
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(AppTheme.Palette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AppTheme.Palette.accent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let bot = editingBot {
                EditBotSheet(bot: bot)
                    .id(bot.id)
            } else {
                CreateBotSheet()
                    .id("create-new-bot-sheet")
            }
        }
        .confirmationDialog("Delete Bot?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let bot = botToDelete {
                    bm.deleteBot(bot)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the Bot's profile and conversation. Files on the shared computer are not deleted.")
        }
        .alert("Import Playbook from URL", isPresented: $showImportURLAlert) {
            TextField("https://raw.githubusercontent.com/.../team.json", text: $importURLString)
            Button("Import") {
                importPlaybookURL()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a direct URL to a Team Playbook JSON or Markdown file.")
        }
    }
    
    // MARK: - Playbook Actions
    
    private func runPlaybookPreset(_ preset: CollaborationPlaybook) {
        let runner = PlaybookRunner(playbook: preset, availableBots: bm.allBots, botManager: bm)
        bm.activePlaybookRunner = runner
        notify("Running playbook: \(preset.name)")
        Task {
            _ = try? await runner.execute(contextInput: "Starting \(preset.name) run")
        }
    }

    private func exportPlaybookJSON() {
        let playbook = bm.exportPlaybook(name: "ApexAgent Team", description: "Exported team configuration")
        guard let data = try? playbook.encode(),
              let str = String(data: data, encoding: .utf8) else { return }
        
        let panel = NSSavePanel()
        panel.title = "Export Team Playbook (JSON)"
        panel.nameFieldStringValue = "apex-team.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try str.write(to: url, atomically: true, encoding: .utf8)
                notify("Exported to \(url.lastPathComponent)")
            } catch {
                notify("Export failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func exportPlaybookMarkdown() {
        let playbook = bm.exportPlaybook(name: "ApexAgent Team", description: "Exported team configuration")
        let md = playbook.toMarkdown()
        
        let panel = NSSavePanel()
        panel.title = "Export Team Playbook (Markdown)"
        panel.nameFieldStringValue = "apex-team.md"
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        }
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try md.write(to: url, atomically: true, encoding: .utf8)
                notify("Exported to \(url.lastPathComponent)")
            } catch {
                notify("Export failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func importPlaybookFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Team Playbook"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.json, .plainText]
        if let mdType = UTType(filenameExtension: "md") {
            types.append(mdType)
        }
        panel.allowedContentTypes = types
        
        if panel.runModal() == .OK, let url = panel.url,
           let data = try? Data(contentsOf: url) {
            if let playbook = try? TeamPlaybook.decode(from: data) {
                let imported = bm.importPlaybook(playbook)
                notify("Imported \(imported.count) bot(s)")
            } else if let str = String(data: data, encoding: .utf8),
                      let playbook = try? TeamPlaybook.decodeFromMarkdown(str) {
                let imported = bm.importPlaybook(playbook)
                notify("Imported \(imported.count) bot(s)")
            } else {
                notify("Failed to parse playbook format")
            }
        }
    }
    
    private func importPlaybookURL() {
        guard let url = URL(string: importURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            notify("Invalid URL")
            return
        }
        Task { @MainActor in
            do {
                let imported = try await bm.importPlaybookFromURL(url)
                notify("Imported \(imported.count) bot(s) from URL")
            } catch {
                notify("Import failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func notify(_ msg: String) {
        playbookNotification = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if playbookNotification == msg {
                playbookNotification = nil
            }
        }
    }
}

// MARK: - Bot Sidebar Item

struct BotSidebarItem: View {
    let bot: BotProfile
    let isActive: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(isActive ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.12))
                        .frame(width: 24, height: 24)
                    Image(systemName: bot.avatarName)
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? .white : Color.accentColor)
                }
                
                // Name and title
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(bot.name)
                            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? .white : .primary)
                            .lineLimit(1)
                        if bot.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(isActive ? .white.opacity(0.7) : .secondary)
                        }
                    }
                    if !bot.title.isEmpty {
                        Text(bot.title)
                            .font(.system(size: 10))
                            .foregroundStyle(isActive ? .white.opacity(0.7) : .secondary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Hover actions
                if isHovered {
                    HStack(spacing: 2) {
                        Button {
                            onTogglePin()
                        } label: {
                            Image(systemName: bot.isPinned ? "pin.slash" : "pin")
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16, height: 16)
                        .help(bot.isPinned ? "Unpin" : "Pin to top")
                        
                        Button {
                            onEdit()
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 9))
                                .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16, height: 16)
                        .help("Edit Bot")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isActive ? Color.accentColor : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("botSidebarItem_\(bot.name)")
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(bot.isPinned ? "Unpin Bot" : "Pin Bot") {
                onTogglePin()
            }
            Button("Edit Bot...") {
                onEdit()
            }
            Divider()
            Button("Delete Bot", role: .destructive) {
                onDelete()
            }
        }
    }
}
