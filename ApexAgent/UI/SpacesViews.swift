import SwiftUI
import SwiftData
import AppKit

// MARK: - Sidebar Section for Spaces

struct SpacesSidebarSection: View {
    @Bindable var spaceManager: SpaceManager
    @Environment(BotManager.self) private var botManager
    @State private var showCreateSpaceSheet = false
    @State private var showCreateChannelSheet = false
    @State private var targetSpaceForChannel: SpaceModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.accent)
                Text("Spaces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
                Spacer()
                Text("\(spaceManager.spaces.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Button {
                    showCreateSpaceSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Create New Space")
                .accessibilityIdentifier("createSpaceSidebarButton")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(spaceManager.spaces) { space in
                        SpaceSidebarGroup(
                            space: space,
                            spaceManager: spaceManager,
                            onAddChannel: {
                                targetSpaceForChannel = space
                                showCreateChannelSheet = true
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 220)
        }
        .sheet(isPresented: $showCreateSpaceSheet) {
            CreateSpaceSheet(spaceManager: spaceManager)
        }
        .sheet(isPresented: $showCreateChannelSheet) {
            if let space = targetSpaceForChannel ?? spaceManager.activeSpace {
                CreateSpaceChannelSheet(space: space, spaceManager: spaceManager)
            }
        }
    }
}

private struct SpaceSidebarGroup: View {
    let space: SpaceModel
    @Bindable var spaceManager: SpaceManager
    let onAddChannel: () -> Void
    @State private var isExpanded = true

    private var isSpaceSelected: Bool {
        spaceManager.activeSpaceId == space.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Space Row
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Button {
                    spaceManager.selectSpace(space)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: space.iconName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Palette.accent)
                        Text(space.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(space.humanParticipants.count)H • \(space.agentParticipants.count)A")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                    }
                }
                .buttonStyle(.plain)

                Button(action: onAddChannel) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Add Channel to \(space.name)")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSpaceSelected ? AppTheme.Palette.accent.opacity(0.10) : Color.clear)
            )

            // Channels list
            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(space.sortedChannels) { channel in
                        let isSelected = (spaceManager.activeChannelId == channel.id) && (spaceManager.botManager?.activeBotId == nil)
                        let isGenerating = spaceManager.channelGenerating[channel.id] == true

                        Button {
                            spaceManager.selectChannel(channel)
                        } label: {
                            HStack(spacing: 6) {
                                Text("#")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    .foregroundStyle(isSelected ? AppTheme.Palette.accent : .secondary)
                                Text(channel.name)
                                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                                    .lineLimit(1)
                                Spacer()
                                if isGenerating {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else if !channel.rootMessages.isEmpty {
                                    Text("\(channel.rootMessages.count)")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.leading, 22)
                            .padding(.trailing, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? AppTheme.Palette.accent.opacity(0.16) : Color.clear)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("spaceChannel_\(channel.name)")
                    }
                }
            }
        }
    }
}

// MARK: - Main Space Workspace View

struct SpaceWorkspaceView: View {
    @Bindable var spaceManager: SpaceManager
    @Environment(BotManager.self) private var botManager

    @State private var inputText = ""
    @State private var threadInputText = ""
    @State private var showInspector = true
    @State private var inspectorTab: SpaceInspectorTab = .roster
    @State private var showAddMemberSheet = false
    @State private var showNewChannelSheet = false
    @State private var modifyingProposal: SpacePageProposal?
    @FocusState private var isComposerFocused: Bool

    enum SpaceInspectorTab: String, CaseIterable, Identifiable {
        case roster = "Members"
        case pages = "Pages"
        case thread = "Thread"

        var id: String { rawValue }
    }

    var body: some View {
        if let space = spaceManager.activeSpace,
           let channel = spaceManager.activeChannel {
            HStack(spacing: 0) {
                // Center: Channel Header + Multi-Party Feed + Mention Composer
                VStack(spacing: 0) {
                    SpaceChannelHeaderBar(
                        space: space,
                        channel: channel,
                        spaceManager: spaceManager,
                        showInspector: $showInspector,
                        inspectorTab: $inspectorTab,
                        onAddMember: { showAddMemberSheet = true },
                        onNewChannel: { showNewChannelSheet = true }
                    )

                    Divider()

                    // Active Speaker Banner
                    if spaceManager.channelGenerating[channel.id] == true {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("\(spaceManager.activeSpeakerByChannel[channel.id] ?? "Agent") is responding in #\(channel.name)...")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Palette.accent)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(AppTheme.Palette.accent.opacity(0.08))
                    }

                    // Pending Proposals Banner (Approve / Deny / Change)
                    if !space.pendingProposals.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(space.pendingProposals) { proposal in
                                SpaceProposalReviewCard(
                                    proposal: proposal,
                                    spaceManager: spaceManager,
                                    onModify: {
                                        modifyingProposal = proposal
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }

                    // Messages ScrollView
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                               ForEach(channel.rootMessages) { message in
                                    SpaceMessageBubbleView(
                                        message: message,
                                        channel: channel,
                                        space: space,
                                        onOpenThread: {
                                            spaceManager.activeThreadParentId = message.id
                                            inspectorTab = .thread
                                            showInspector = true
                                        },
                                        onMentionClick: { handle in
                                            insertMention(handle)
                                        }
                                    )
                                    .id(message.id)
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id("spaceBottom")
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                        }
                        .onChange(of: channel.messages.count) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("spaceBottom", anchor: .bottom)
                            }
                        }
                    }

                    Divider()

                    // Quick @Mention Roster Bar + Rich Composer
                    SpaceComposerView(
                        space: space,
                        channel: channel,
                        spaceManager: spaceManager,
                        inputText: $inputText,
                        isFocused: $isComposerFocused,
                        onSend: {
                            let text = inputText
                            inputText = ""
                            _ = spaceManager.postHumanMessage(text, in: channel)
                        }
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Right Drawer: Roster (Humans + Agents + Invite Link) | Shared Pages | Thread Replies
                if showInspector {
                    Divider()
                    SpaceInspectorDrawer(
                        space: space,
                        channel: channel,
                        spaceManager: spaceManager,
                        selectedTab: $inspectorTab,
                        threadInputText: $threadInputText,
                        onAddMember: { showAddMemberSheet = true }
                    )
                    .frame(width: 320)
                    .transition(.move(edge: .trailing))
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .sheet(isPresented: $showAddMemberSheet) {
                AddSpaceParticipantSheet(space: space, spaceManager: spaceManager)
            }
            .sheet(isPresented: $showNewChannelSheet) {
                CreateSpaceChannelSheet(space: space, spaceManager: spaceManager)
            }
            .sheet(item: $modifyingProposal) { proposal in
                ChangeProposalSheet(proposal: proposal, spaceManager: spaceManager)
            }
        } else {
            ContentUnavailableView(
                "No Space Selected",
                systemImage: "sparkles.rectangle.stack",
                description: Text("Select or create a Space in the sidebar to collaborate with all bots and human teammates.")
            )
        }
    }

    private func insertMention(_ handle: String) {
        let token = "@\(handle) "
        if !inputText.contains(token) {
            inputText += (inputText.isEmpty || inputText.hasSuffix(" ")) ? token : " \(token)"
        }
        isComposerFocused = true
    }
}

// MARK: - Channel Header Bar

private struct SpaceChannelHeaderBar: View {
    @Bindable var space: SpaceModel
    let channel: SpaceChannel
    @Bindable var spaceManager: SpaceManager
    @Binding var showInspector: Bool
    @Binding var inspectorTab: SpaceWorkspaceView.SpaceInspectorTab
    let onAddMember: () -> Void
    let onNewChannel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Channel Title & Topic
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(space.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Text("#\(channel.name)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                if !channel.topic.isEmpty {
                    Text(channel.topic)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Orchestration Mode Picker
            Picker(
                selection: Binding(
                    get: { space.orchestrationMode },
                    set: { newMode in
                        space.orchestrationMode = newMode
                        try? spaceManager.modelContext?.save()
                    }
                ),
                label: Label("Mode", systemImage: space.orchestrationMode.symbolName)
            ) {
                ForEach(SpaceOrchestrationMode.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 165)
            .help("Space Orchestration Mode: controls how unmentioned messages route to bots")
            .accessibilityIdentifier("spaceOrchestrationModePicker")

            // Participant Count Pill
            Button {
                inspectorTab = .roster
                showInspector = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 11))
                    Text("\(space.humanParticipants.count) Humans")
                        .font(.system(size: 11, weight: .medium))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Image(systemName: "cpu")
                        .font(.system(size: 11))
                    Text("\(space.agentParticipants.count) Agents")
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("View Space Members (Humans & Bots)")

            // Add Human / Bot Button
            Button(action: onAddMember) {
                Label("Add Member", systemImage: "person.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(AppTheme.Palette.accent)
            .accessibilityIdentifier("addSpaceMemberButton")

            // Shared Pages Shortcut
            Button {
                inspectorTab = .pages
                showInspector = true
            } label: {
                Label("Pages (\(space.pages.count))", systemImage: "doc.richtext")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("spacePagesDrawerButton")

            // Inspector Toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showInspector.toggle()
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showInspector ? AppTheme.Palette.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help("Toggle Space Inspector")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Multi-Party Message Bubble View

private struct SpaceMessageBubbleView: View {
    let message: SpaceMessage
    let channel: SpaceChannel
    let space: SpaceModel
    let onOpenThread: () -> Void
    let onMentionClick: (String) -> Void

    private var replyCount: Int {
        channel.threadReplies(for: message.id).count
    }

    private var badgeColor: Color {
        switch message.senderKind {
        case .human: return Color.blue
        case .bot: return AppTheme.Palette.accent
        case .system: return Color.orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(badgeColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: message.senderAvatarSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(badgeColor)
            }

            VStack(alignment: .leading, spacing: 5) {
                // Header: Name + @handle + Role Badge + Timestamp
                HStack(spacing: 6) {
                    Text(message.senderName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)

                    Button {
                        onMentionClick(message.senderHandle)
                    } label: {
                        Text("@\(message.senderHandle)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Text(message.senderKind == .human ? "HUMAN" : (message.senderKind == .bot ? "AGENT" : "SYSTEM"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(badgeColor.opacity(0.12))
                        .clipShape(Capsule())

                    Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button(action: onOpenThread) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.system(size: 10))
                            Text(replyCount > 0 ? "\(replyCount) repl\(replyCount == 1 ? "y" : "ies")" : "Reply")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(replyCount > 0 ? AppTheme.Palette.accent : .secondary)
                    }
                    .buttonStyle(.plain)
                }

                // Mention Pills if any
                if !message.mentionedHandles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.mentionedHandles, id: \.self) { handle in
                            Text("@\(handle)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(AppTheme.Palette.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(AppTheme.Palette.accent.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                // Body
                Text(.init(message.content))
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .windowBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(badgeColor.opacity(0.22), lineWidth: 0.8)
                    )
                    .contextMenu {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        } label: {
                            Label("Copy Message Text", systemImage: "doc.on.doc")
                        }

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("apex://spaces/\(space.id)/\(channel.id)/\(message.id)", forType: .string)
                        } label: {
                            Label("Copy Message Link", systemImage: "link")
                        }

                        Divider()

                        Button(action: onOpenThread) {
                            Label("Reply in Thread", systemImage: "arrowshape.turn.up.left")
                        }
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("spaceMessage_\(message.id.uuidString)")
    }
}

// MARK: - Space Composer with @Mention Quick Chips & Human Identity Switcher

private struct SpaceComposerView: View {
    let space: SpaceModel
    let channel: SpaceChannel
    @Bindable var spaceManager: SpaceManager
    @Binding var inputText: String
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var isChannelGenerating: Bool {
        spaceManager.channelGenerating[channel.id] == true
    }

    private var hasInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quick @Mention Bar (All Bots + All Humans + @all)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Tag:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    MentionChipButton(label: "@all", icon: "sparkles", color: .orange) {
                        appendToken("@all")
                    }

                    ForEach(space.agentParticipants) { agent in
                        MentionChipButton(
                            label: "@\(agent.handle)",
                            icon: agent.avatarSymbol,
                            color: AppTheme.Palette.accent
                        ) {
                            appendToken("@\(agent.handle)")
                        }
                    }

                    ForEach(space.humanParticipants) { human in
                        MentionChipButton(
                            label: "@\(human.handle)",
                            icon: "person.fill",
                            color: .blue
                        ) {
                            appendToken("@\(human.handle)")
                        }
                    }
                }
                .padding(.horizontal, 14)
            }

            // Input Row + Active Human Identity Picker
            HStack(spacing: 10) {
                // Human Sender Selector (lets you post as Yourself or any added Human teammate)
                if !space.humanParticipants.isEmpty {
                    Menu {
                        Section("Post as Human User") {
                            ForEach(space.humanParticipants) { human in
                                Button {
                                    spaceManager.activeLocalHumanParticipantId = human.id
                                } label: {
                                    Label("\(human.displayName) (@\(human.handle))", systemImage: human.avatarSymbol)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: spaceManager.activeHumanSender?.avatarSymbol ?? "person.crop.circle.fill")
                                .foregroundStyle(.blue)
                            Text(spaceManager.activeHumanSender?.displayName ?? "You")
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Select which human participant is sending this message")
                }

                TextField(
                    "Message #\(channel.name) — tag @bot to summon an agent, @all for everyone, or @human to chat with a teammate...",
                    text: $inputText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .focused(isFocused)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .windowBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .onSubmit {
                    if hasInput {
                        onSend()
                    }
                }
                .accessibilityIdentifier("spaceComposerTextField")

                if isChannelGenerating {
                    if !hasInput {
                        Button(action: {
                            spaceManager.cancelChannelGeneration(channelId: channel.id)
                        }) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Stop active generation in #\(channel.name)")
                        .accessibilityIdentifier("spaceStopButton")
                    } else {
                        HStack(spacing: 6) {
                            Button(action: {
                                spaceManager.cancelChannelGeneration(channelId: channel.id)
                            }) {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Stop active generation in #\(channel.name)")
                            .accessibilityIdentifier("spaceStopButton")

                            Button(action: onSend) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundStyle(AppTheme.Palette.accent)
                            }
                            .buttonStyle(.plain)
                            .help("Send message to channel")
                            .accessibilityIdentifier("spaceSendButton")
                        }
                    }
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(
                                !hasInput
                                ? Color.secondary.opacity(0.4)
                                : AppTheme.Palette.accent
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasInput)
                    .accessibilityIdentifier("spaceSendButton")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .padding(.top, 8)
    }

    private func appendToken(_ token: String) {
        if inputText.isEmpty || inputText.hasSuffix(" ") {
            inputText += "\(token) "
        } else {
            inputText += " \(token) "
        }
        isFocused.wrappedValue = true
    }
}

private struct MentionChipButton: View {
    let label: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.10))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Right Inspector Drawer (Members Roster | Shared Space Pages | Thread Replies)

private struct SpaceInspectorDrawer: View {
    let space: SpaceModel
    let channel: SpaceChannel
    @Bindable var spaceManager: SpaceManager
    @Binding var selectedTab: SpaceWorkspaceView.SpaceInspectorTab
    @Binding var threadInputText: String
    let onAddMember: () -> Void

    @State private var copiedInvite = false
    @State private var newPageTitle = ""

    var body: some View {
        VStack(spacing: 0) {
            // Segmented Picker
            Picker("", selection: $selectedTab) {
                ForEach(SpaceWorkspaceView.SpaceInspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            switch selectedTab {
            case .roster:
                rosterTabContent
            case .pages:
                pagesTabContent
            case .thread:
                threadTabContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 1. Roster Tab (Humans + Bots + Invite Link)
    private var rosterTabContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Multi-Human Invite Card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(AppTheme.Palette.accent)
                        Text("Invite Human Teammates")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("Add User") {
                            onAddMember()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    }
                    Text("Teammates on your LAN/Tailscale or local Mac can join this Space and chat alongside all bots.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Text(spaceManager.inviteURL(for: space))
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(spaceManager.inviteURL(for: space), forType: .string)
                            copiedInvite = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedInvite = false
                            }
                        } label: {
                            Text(copiedInvite ? "Copied!" : "Copy")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(AppTheme.Palette.accent.opacity(0.06))
                )

                // Human Participants Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("HUMAN TEAMMATES (\(space.humanParticipants.count))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            onAddMember()
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(space.humanParticipants) { human in
                        HStack(spacing: 8) {
                            Image(systemName: human.avatarSymbol)
                                .foregroundStyle(.blue)
                                .font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(human.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(human.role.badgeLabel)
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .clipShape(Capsule())
                                }
                                Text("@\(human.handle) • \(human.roleTitle)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if spaceManager.activeLocalHumanParticipantId == human.id {
                                Text("Active")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Act As") {
                                    spaceManager.activeLocalHumanParticipantId = human.id
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    }
                }

                Divider()

                // AI Agent Teammates Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("AI AGENT TEAMMATES (\(space.agentParticipants.count))")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Sync All Bots") {
                            spaceManager.syncBotParticipants(in: space)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    ForEach(space.agentParticipants) { agent in
                        HStack(spacing: 8) {
                            Image(systemName: agent.avatarSymbol)
                                .foregroundStyle(AppTheme.Palette.accent)
                                .font(.system(size: 14))
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(agent.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("@\(agent.handle) • \(agent.roleTitle)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Circle()
                                .fill(agent.presenceState == .generating ? Color.orange : Color.green)
                                .frame(width: 7, height: 7)
                        }
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: 2. Shared Space Pages Tab
    private var pagesTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("SHARED PAGES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let page = spaceManager.createPage(
                        in: space,
                        title: "Untitled Spec \(space.pages.count + 1)",
                        markdownBody: "# New Shared Page\n\nCollaborate with humans and @bots here.",
                        authorName: spaceManager.activeHumanSender?.displayName ?? "User"
                    )
                    spaceManager.activePageId = page.id
                } label: {
                    Label("New Page", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Page Selector Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(space.sortedPages) { page in
                        let isSelected = spaceManager.activePage?.id == page.id
                        Button {
                            spaceManager.activePageId = page.id
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.fill")
                                    .font(.system(size: 10))
                                Text(page.title)
                                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isSelected ? AppTheme.Palette.accent.opacity(0.18) : Color.primary.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                spaceManager.deletePage(page, from: space)
                            } label: {
                                Label("Delete Page", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider()

            if let page = spaceManager.activePage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField(
                            "Page Title",
                            text: Binding(
                                get: { page.title },
                                set: { spaceManager.updatePage(page, title: $0, editorName: spaceManager.activeHumanSender?.displayName ?? "User") }
                            )
                        )
                        .font(.system(size: 14, weight: .bold))
                        .textFieldStyle(.plain)

                        Spacer()

                        Button {
                            spaceManager.deletePage(page, from: space)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Delete this page")
                    }

                    Text("Last edited by \(page.lastEditedByName) • \(page.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    TextEditor(
                        text: Binding(
                            get: { page.markdownBody },
                            set: { spaceManager.updatePage(page, markdownBody: $0, editorName: spaceManager.activeHumanSender?.displayName ?? "User") }
                        )
                    )
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                }
                .padding(12)
            } else {
                Spacer()
            }
        }
    }

    // MARK: 3. Thread Replies Tab
    private var threadTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parentId = spaceManager.activeThreadParentId,
               let parentMsg = channel.messages.first(where: { $0.id == parentId }) {
                HStack {
                    Text("Thread in #\(channel.name)")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Button {
                        spaceManager.activeThreadParentId = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        // Parent Message
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(parentMsg.senderName) (@\(parentMsg.senderHandle))")
                                .font(.system(size: 11, weight: .semibold))
                            Text(parentMsg.content)
                                .font(.system(size: 12))
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(AppTheme.Palette.accent.opacity(0.08)))

                        Divider()

                        // Thread Replies
                        ForEach(channel.threadReplies(for: parentId)) { reply in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(reply.senderName)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("@\(reply.senderHandle)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(reply.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(reply.content)
                                    .font(.system(size: 12))
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        }
                    }
                    .padding(.horizontal, 12)
                }

                Divider()

                HStack(spacing: 6) {
                    TextField("Reply in thread (@bot or @human)...", text: $threadInputText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit {
                            sendThreadReply(parentId: parentId)
                        }
                    Button("Reply") {
                        sendThreadReply(parentId: parentId)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(threadInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            } else {
                ContentUnavailableView(
                    "No Active Thread",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Click 'Reply' on any message in the channel to start or view a focused thread.")
                )
            }
        }
    }

    private func sendThreadReply(parentId: UUID) {
        let text = threadInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        threadInputText = ""
        _ = spaceManager.postHumanMessage(
            text,
            in: channel,
            threadParentId: parentId
        )
    }
}

// MARK: - Sheets: Create Space, Create Channel, Add Human / Bot Member

struct CreateSpaceSheet: View {
    @Bindable var spaceManager: SpaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var summary = ""
    @State private var mode: SpaceOrchestrationMode = .mentionDriven

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create New Space")
                .font(.headline)

            TextField("Space Name (e.g. Core Platform, Product Launch)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Shared Context / Purpose", text: $summary)
                .textFieldStyle(.roundedBorder)

            Picker("Default Orchestration Mode", selection: $mode) {
                ForEach(SpaceOrchestrationMode.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create Space") {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    let space = spaceManager.createSpace(
                        name: clean,
                        summary: summary,
                        orchestrationMode: mode,
                        seedDefaults: true
                    )
                    spaceManager.selectSpace(space)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct CreateSpaceChannelSheet: View {
    let space: SpaceModel
    @Bindable var spaceManager: SpaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var topic = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create Channel in \(space.name)")
                .font(.headline)

            TextField("Channel Name (e.g. security-audit, ui-polish)", text: $name)
                .textFieldStyle(.roundedBorder)

            TextField("Channel Topic / Instructions", text: $topic)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create #Channel") {
                    let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return }
                    let channel = spaceManager.addChannel(to: space, name: clean, topic: topic)
                    spaceManager.selectChannel(channel)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct AddSpaceParticipantSheet: View {
    let space: SpaceModel
    @Bindable var spaceManager: SpaceManager
    @Environment(BotManager.self) private var botManager
    @Environment(\.dismiss) private var dismiss

    @State private var humanName = ""
    @State private var humanHandle = ""
    @State private var humanRoleTitle = "Software Engineer"
    @State private var humanRole: SpaceParticipantRole = .member

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Teammates to \(space.name)")
                .font(.headline)

            GroupBox("Add Human User") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Full Name (e.g. Alex Rivera)", text: $humanName)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        TextField("@handle (optional)", text: $humanHandle)
                            .textFieldStyle(.roundedBorder)
                        TextField("Title / Role", text: $humanRoleTitle)
                            .textFieldStyle(.roundedBorder)
                    }
                    Picker("Permission Role", selection: $humanRole) {
                        Text("Member").tag(SpaceParticipantRole.member)
                        Text("Admin").tag(SpaceParticipantRole.admin)
                        Text("Guest").tag(SpaceParticipantRole.guest)
                    }
                    HStack {
                        Spacer()
                        Button("Add Human to Space") {
                            let clean = humanName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !clean.isEmpty else { return }
                            _ = spaceManager.addHumanParticipant(
                                to: space,
                                displayName: clean,
                                handle: humanHandle.isEmpty ? nil : humanHandle,
                                roleTitle: humanRoleTitle,
                                role: humanRole,
                                isRemote: true
                            )
                            humanName = ""
                            humanHandle = ""
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(humanName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(8)
            }

            GroupBox("Add AI Bots from Roster") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(botManager.allBots) { bot in
                        let alreadyInSpace = space.agentParticipants.contains { $0.botProfileId == bot.id }
                        HStack {
                            Image(systemName: bot.avatarName)
                                .foregroundStyle(AppTheme.Palette.accent)
                            Text(bot.name)
                                .font(.system(size: 12, weight: .semibold))
                            Text("— \(bot.title)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if alreadyInSpace {
                                Label("Joined", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Add Bot") {
                                    _ = spaceManager.addBotParticipant(to: space, bot: bot)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Space Proposal Review Card (Approve / Deny / Change)

struct SpaceProposalReviewCard: View {
    let proposal: SpacePageProposal
    @Bindable var spaceManager: SpaceManager
    let onModify: () -> Void

    @State private var showDiffPreview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Page Proposal: \(proposal.pageTitle)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("By \(proposal.authorName) • \(proposal.summary)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation { showDiffPreview.toggle() }
                } label: {
                    Text(showDiffPreview ? "Hide Preview" : "View Preview")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            if showDiffPreview {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Proposed Content:")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(proposal.proposedContent)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            }

            HStack(spacing: 8) {
                Button {
                    spaceManager.approveProposal(proposal, editorName: spaceManager.activeHumanSender?.displayName ?? "User")
                } label: {
                    Label("Approve", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)

                Button {
                    spaceManager.denyProposal(proposal, reason: "Denied by user")
                } label: {
                    Label("Deny", systemImage: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Button {
                    onModify()
                } label: {
                    Label("Change", systemImage: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Change Proposal Sheet

struct ChangeProposalSheet: View {
    let proposal: SpacePageProposal
    @Bindable var spaceManager: SpaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var editedContent: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Change & Approve: \(proposal.pageTitle)")
                        .font(.headline)
                    Text("Edit the proposed content directly before merging into the space page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
            }

            TextEditor(text: $editedContent)
                .font(.system(size: 12.5, design: .monospaced))
                .frame(minWidth: 500, minHeight: 350)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            HStack {
                Spacer()
                Button("Approve With Changes") {
                    spaceManager.modifyAndApproveProposal(
                        proposal,
                        modifiedContent: editedContent,
                        editorName: spaceManager.activeHumanSender?.displayName ?? "User"
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(16)
        .onAppear {
            editedContent = proposal.proposedContent
        }
    }
}
