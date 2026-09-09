import SwiftUI
import SwiftData
import AppKit
import FoundationModels
import UniformTypeIdentifiers

// MARK: - Bot Sidebar Section

struct BotSidebarSection: View {
    @Bindable var bm: BotManager
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
                    Divider()
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
            } else {
                CreateBotSheet()
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
    
    private func exportPlaybookJSON() {
        let playbook = bm.exportPlaybook(name: "ApexAgent Team", description: "Exported team configuration")
        guard let data = try? playbook.encode(),
              let str = String(data: data, encoding: .utf8) else { return }
        
        let panel = NSSavePanel()
        panel.title = "Export Team Playbook (JSON)"
        panel.nameFieldStringValue = "apex-team.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? str.write(to: url, atomically: true, encoding: .utf8)
            notify("Exported to \(url.lastPathComponent)")
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
            try? md.write(to: url, atomically: true, encoding: .utf8)
            notify("Exported to \(url.lastPathComponent)")
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
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Avatar
                Image(systemName: bot.avatarName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isActive ? .white : AppTheme.Palette.accent)
                    .frame(width: 24, height: 24)
                    .background(
                        isActive
                            ? AnyShapeStyle(AppTheme.Palette.accent)
                            : AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                    )
                    .clipShape(Circle())
                
                // Name + title
                VStack(alignment: .leading, spacing: 1) {
                    Text(bot.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                    if !bot.title.isEmpty {
                        Text(bot.title)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                // Status indicator
                if bot.lastActiveAt.timeIntervalSinceNow > -300 {
                    // Active in last 5 min
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
                
                // Context menu (edit, pin, delete)
                Menu {
                    Button {
                        onTogglePin()
                    } label: {
                        Label(
                            bot.isPinned ? "Unpin from Top" : "Pin to Top",
                            systemImage: bot.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit Bot", systemImage: "pencil")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Bot", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isActive
                    ? AppTheme.Palette.accent.opacity(0.1)
                    : Color.clear
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? AppTheme.Palette.accent.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("botSidebarItem_\(bot.name)")
        .contextMenu {
            Button {
                onTogglePin()
            } label: {
                Label(
                    bot.isPinned ? "Unpin" : "Pin to Top",
                    systemImage: bot.isPinned ? "pin.slash" : "pin"
                )
            }
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete Bot", systemImage: "trash")
            }
        }
    }
}

// MARK: - Bot Status Badge

struct BotStatusBadge: View {
    @Environment(BotManager.self) private var bm
    
    var body: some View {
        HStack(spacing: 4) {
            if let session = bm.activeSession {
                // Show model status based on session's model preference
                Circle()
                    .fill(statusColor(for: session.modelPreference, availability: session.modelAvailability))
                    .frame(width: 7, height: 7)
                Text(statusText(for: session))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.orange)
                    .frame(width: 7, height: 7)
                Text("No Bot")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
    }
    
    private func statusColor(for preference: AgentModelPreference, availability: SystemLanguageModel.Availability) -> Color {
        switch preference {
        case .autoPicker:
            return .green
        case .localSystem:
            return availability == .available ? .green : .red
        case .privateCloud:
            return .blue
        case .cloudGemini:
            return .purple
        case .localOllama, .localMLX:
            return .orange
        case .hybrid:
            return .green
        }
    }
    
    private func statusText(for session: BotSession) -> String {
        switch session.modelPreference {
        case .autoPicker:
            return "Auto"
        case .localSystem:
            return session.modelAvailability == .available ? "AFM 3" : "Offline"
        case .privateCloud:
            return "PCC"
        case .cloudGemini:
            return "Gemini"
        case .localOllama:
            return "Ollama"
        case .localMLX:
            return "MLX"
        case .hybrid:
            return "Hybrid"
        }
    }
}
