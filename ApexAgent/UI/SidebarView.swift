import SwiftUI

struct SidebarView: View {
    let conversations: [Conversation]
    let selectedConversation: Conversation?
    let onSelectConversation: (Conversation) -> Void
    let onDeleteConversations: (IndexSet) -> Void

    var body: some View {
        List {
            if conversations.isEmpty {
                EmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "No Chats Yet",
                    message: "Start a new conversation to begin.",
                    actionTitle: nil,
                    action: nil
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .frame(maxHeight: .infinity)
            } else {
                ForEach(conversations) { conversation in
                    ConversationRow(
                        conversation: conversation,
                        isSelected: selectedConversation?.id == conversation.id
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(
                        selectedConversation?.id == conversation.id
                        ? AppTheme.Palette.accent.opacity(0.12)
                        : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelectConversation(conversation) }
                }
                .onDelete(perform: onDeleteConversations)
            }
        }
        .listStyle(.plain)
    }
}

struct ConversationRow: View {
    let conversation: Conversation
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title.isEmpty ? "New Conversation" : conversation.title)
                    .font(AppTheme.Font.headline(isSelected ? 13 : 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text(conversation.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(AppTheme.Font.caption(10))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                    .textSelection(.disabled)
            }
            Spacer()
            if isSelected {
                Circle()
                    .fill(AppTheme.Palette.accent)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.vertical, 4)
    }
}
