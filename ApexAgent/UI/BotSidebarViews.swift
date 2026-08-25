import SwiftUI
import SwiftData
import AppKit
import FoundationModels

// MARK: - Bot Sidebar Section

struct BotSidebarSection: View {
    @Bindable var bm: BotManager
    @State private var showEditSheet = false
    @State private var editingBot: BotProfile?
    @State private var showDeleteConfirm = false
    @State private var botToDelete: BotProfile?
    
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
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
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
