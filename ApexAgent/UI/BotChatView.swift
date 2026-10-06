import SwiftUI
import AppKit
import FoundationModels
import SwiftData

// MARK: - Bot Chat View

struct BotChatView: View {
    var session: BotSession
    @Environment(BotManager.self) private var botManager
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            BotChatHeaderBar(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))

            ForEach(botManager.pendingPeerApprovals.filter { $0.fromBotId == session.bot.id.uuidString }) { request in
                PeerApprovalCard(request: request, botManager: botManager)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if let runner = botManager.activePlaybookRunner,
               let card = runner.pendingApprovalCard {
                PlaybookApprovalBannerView(card: card, runner: runner)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
            
            Divider()
            
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if session.messages.isEmpty {
                            BotWelcomeView(session: session)
                                .padding(.top, 40)
                        } else {
                            ForEach(session.messages) { message in
                                BotMessageRow(message: message, bot: session.bot)
                                    .id(message.id)
                            }
                        }
                        
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: session.messages.count) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: session.messages.last?.content) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            
            Divider()
            
            // Input bar
            BotChatInputBar(session: session, inputText: $inputText, isInputFocused: $isInputFocused)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .task {
            do {
                while true {
                    try await Task.sleep(for: .seconds(60))
                    botManager.expireStalePeerApprovals()
                }
            } catch is CancellationError {
                // The view leaving the hierarchy cancels the expiry poll.
            } catch {
                print("Peer approval expiry poll stopped: \(error.localizedDescription)")
            }
        }
        .onAppear {
            isInputFocused = true
            session.checkAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ApexAgent.focusChatInput"))) { _ in
            isInputFocused = true
        }
    }
}

private struct PeerApprovalCard: View {
    let request: PendingPeerApproval
    let botManager: BotManager

    private var targetName: String {
        guard let id = UUID(uuidString: request.toBotId) else { return "teammate" }
        return botManager.bot(byId: id)?.name ?? "teammate"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Allow \(targetName) to receive this request?")
                .font(.headline)
            Text(request.message)
                .font(.callout)
                .textSelection(.enabled)
            Text("Approving runs this request once. The current agent turn has already stopped; its reply will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Deny") {
                    _ = botManager.resolvePeerRequest(requestId: request.id, allow: false)
                }
                .accessibilityIdentifier("peerApprovalDeny-\(request.id)")
                Spacer()
                Button("Always Allow") {
                    _ = botManager.resolvePeerRequest(requestId: request.id, allow: true, remember: true)
                }
                .accessibilityIdentifier("peerApprovalAlwaysAllow-\(request.id)")
                Button("Allow Once") {
                    _ = botManager.resolvePeerRequest(requestId: request.id, allow: true)
                }
                .accessibilityIdentifier("peerApprovalAllowOnce-\(request.id)")
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("peerApprovalCard-\(request.id)")
    }
}

// MARK: - Bot Chat Header Bar

struct BotChatHeaderBar: View {
    var session: BotSession
    @Environment(BotManager.self) private var botManager
    
    var body: some View {
        HStack(spacing: 10) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: session.bot.avatarName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            
            // Title & Specialty
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.bot.name)
                        .font(.system(size: 13, weight: .semibold))
                    
                    if session.bot.isChiefOfStaff {
                        Text("Chief of Staff")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundStyle(Color.accentColor)
                            .cornerRadius(4)
                    }
                    
                    if AgentRegistry.builtInDefaults[session.bot.name.lowercased()] == nil {
                        Text("Custom")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .cornerRadius(4)
                    }
                }
                
                Text(session.bot.title.isEmpty ? session.bot.descriptionText : session.bot.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            // Queued prompt indicator in header
            if !session.queuedPrompts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11))
                    Text("\(session.queuedPrompts.count)")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(AppTheme.Palette.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(AppTheme.Palette.accent.opacity(0.12))
                .cornerRadius(10)
                .help("\(session.queuedPrompts.count) queued prompt(s)")
            }
            
            // Playbook run menu
            Menu {
                ForEach(CollaborationPlaybook.builtInPresets) { preset in
                    Button {
                        let runner = PlaybookRunner(playbook: preset, availableBots: botManager.allBots, botManager: botManager)
                        botManager.activePlaybookRunner = runner
                        Task {
                            _ = try? await runner.execute(contextInput: "Run \(preset.name) from \(session.bot.name)")
                        }
                    } label: {
                        Label("Run \(preset.name)", systemImage: "play.circle")
                    }
                }
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .help("Run Collaboration Playbook")

            // Clear history button
            Button {
                session.clearMessages()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear chat history")
        }
    }
}

// MARK: - Bot Welcome View

struct BotWelcomeView: View {
    var session: BotSession
    
    var body: some View {
        VStack(spacing: 16) {
            // Large avatar
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: session.bot.avatarName)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 6) {
                Text("Chat with \(session.bot.name)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                
                Text(session.bot.title.isEmpty ? session.bot.descriptionText : session.bot.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            // Model indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(session.modelAvailability == .available ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(session.bot.modelProvider?.displayName ?? "Apple Foundation Models")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(nsColor: .separatorColor).opacity(0.3))
            .cornerRadius(12)
            
            // Builtin suggested prompts
            VStack(spacing: 8) {
                ForEach(suggestedPrompts(for: session.bot), id: \.self) { prompt in
                    Button {
                        session.sendMessage(prompt)
                    } label: {
                        HStack {
                            Text(prompt)
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
    
    private func suggestedPrompts(for bot: BotProfile) -> [String] {
        if bot.isChiefOfStaff {
            return [
                "Summarize recent activity across all bots",
                "Delegate a comprehensive architecture review to the team",
                "What tasks are currently blocked or awaiting input?"
            ]
        }
        let role = (bot.title + " " + bot.descriptionText).lowercased()
        if role.contains("code") || role.contains("architect") {
            return [
                "Review the project structure and suggest improvements",
                "Explain the concurrent tool execution model in ApexAgent"
            ]
        } else if role.contains("research") || role.contains("audit") {
            return [
                "Search documentation for Apple Foundation Models best practices",
                "Analyze memory retention mechanisms across conversations"
            ]
        } else if role.contains("auto") || role.contains("ci") || role.contains("test") {
            return [
                "Run test suites and report any failures",
                "Verify sandbox permissions for terminal tools"
            ]
        } else {
            return [
                "How can you assist me today?",
                "List available tools and capabilities"
            ]
        }
    }
}

// MARK: - Bot Message Row

struct BotMessageRow: View {
    let message: ChatMessage
    let bot: BotProfile
    
    private var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 40)
            } else {
                // Bot avatar
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: bot.avatarName)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.accentColor)
                }
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Attachments preview
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(0..<message.attachments.count, id: \.self) { idx in
                            Image(nsImage: message.attachments[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxHeight: 120)
                                .cornerRadius(8)
                        }
                    }
                }
                
                // Bubble content
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking...")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(12)
                } else if !message.content.isEmpty {
                    Text(LocalizedStringKey(message.content))
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(bubbleBackground)
                        .cornerRadius(12)
                        .accessibilityIdentifier(isUser ? "BotUserMessage_\(message.id)" : "BotAgentResponse_\(message.id)")
                        .accessibilityLabel(message.content)
                        .accessibilityValue(message.content)
                }
            }
            
            if isUser {
                // User icon
                ZStack {
                    Circle()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: "person.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                Spacer(minLength: 40)
            }
        }
    }
    
    private var bubbleBackground: some View {
        Group {
            if isUser {
                Color.accentColor.opacity(0.18)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }
        }
    }
}

// MARK: - Bot Chat Input Bar

struct BotChatInputBar: View {
    var session: BotSession
    @Environment(BotManager.self) private var botManager
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Binding var inputText: String
    @FocusState.Binding var isInputFocused: Bool
    @State private var isHovered = false
    private var voiceController: VoiceController { VoiceController.shared }

    private var hasInputContent: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !session.pendingAttachments.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Queued Prompts Banner
            if !session.queuedPrompts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.Palette.accent)
                        Text("\(session.queuedPrompts.count) prompt\(session.queuedPrompts.count == 1 ? "" : "s") queued")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.Palette.accent)
                        Spacer()
                        Button("Clear Queue") {
                            session.clearPromptQueue()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    
                    // Show queued list preview
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.queuedPrompts) { item in
                                HStack(spacing: 4) {
                                    Text(item.text)
                                        .lineLimit(1)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.primary)
                                    Button {
                                        session.removeQueuedPrompt(id: item.id)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(AppTheme.Palette.accent.opacity(0.08))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.Palette.accent.opacity(0.2), lineWidth: 1)
                )
            }

            // Attachment previews above the input
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<session.pendingAttachments.count, id: \.self) { idx in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: session.pendingAttachments[idx])
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                    )
                                
                                Button {
                                    session.pendingAttachments.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary, Color(nsColor: .windowBackgroundColor))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Attach button
                Button {
                    attachImageFile()
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach Image")
                
                // Screenshot button
                Button {
                    Task {
                        await session.captureAndAttachScreenshot()
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Take Screenshot")
                
                // Voice button
                Button {
                    if voiceController.isRecording {
                        voiceController.stopRecording()
                    } else {
                        try? voiceController.startRecording { transcribed in
                            if !transcribed.isEmpty {
                                self.inputText = transcribed
                            }
                        }
                    }
                } label: {
                    Image(systemName: voiceController.isRecording ? "mic.fill" : "mic")
                        .font(.system(size: 15))
                        .foregroundStyle(voiceController.isRecording ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(voiceController.isRecording ? "Stop Recording" : "Voice Input")

                // Text field
                TextField(session.isGenerating ? "Queue next prompt..." : "Message \(session.bot.name)... (type / for commands)", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isInputFocused)
                    .accessibilityIdentifier("botChatInputField")
                    .lineLimit(1...5)
                    .onSubmit {
                        send()
                    }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.isEmpty {
                            send()
                            return .handled
                        }
                        return .ignored
                    }
                    .onKeyPress(.space, phases: .down) { _ in
                        return .ignored
                    }
                    .onKeyPress(phases: .down) { press in
                        if press.modifiers == .command && press.characters == "v" {
                            return checkPasteboardAndPaste()
                        }
                        return .ignored
                    }
                    .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                        for provider in providers {
                            _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                                if let data, let image = NSImage(data: data) {
                                    DispatchQueue.main.async {
                                        session.pendingAttachments.append(image)
                                    }
                                }
                            }
                        }
                        return true
                    }
                
                if session.isGenerating { 
                    Button {
                        session.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                } else {
                    // Send button
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(hasInputContent ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasInputContent)
                    .accessibilityIdentifier("botSendButton")
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
    
    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !session.pendingAttachments.isEmpty else { return }
        let attachments = session.pendingAttachments
        session.pendingAttachments = []
        inputText = ""

        if BuiltinSlashCommandEngine.isSlashCommand(text) {
            Task { @MainActor in
                let targetOrch = session.orchestrator ?? orchestrator
                if let result = await BuiltinSlashCommandEngine.shared.execute(
                    input: text,
                    orchestrator: targetOrch,
                    botManager: botManager
                ) {
                    if !result.triggeredAgentExecution {
                        session.appendMessage(ChatMessage(role: .assistant, content: result.outputMarkdown))
                    }
                }
            }
            return
        }

        session.sendMessage(text, attachments: attachments)
    }
    
    private func attachImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                if let image = NSImage(contentsOf: url) {
                    session.pendingAttachments.append(image)
                }
            }
        }
    }
    
    private func checkPasteboardAndPaste() -> KeyPress.Result {
        let pb = NSPasteboard.general

        // 1. Direct Image Data (TIFF/PNG)
        if let tiff = pb.data(forType: .tiff), let image = NSImage(data: tiff) {
            session.pendingAttachments.append(image)
            return .handled
        }
        if let png = pb.data(forType: .png), let image = NSImage(data: png) {
            session.pendingAttachments.append(image)
            return .handled
        }

        // 2. File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    session.pendingAttachments.append(image)
                    return .handled
                }
            }
        }

        return .ignored
    }
}

// MARK: - Playbook Approval Banner View

struct PlaybookApprovalBannerView: View {
    let card: PlaybookApprovalCard
    let runner: PlaybookRunner
    @Environment(BotManager.self) private var botManager
    @State private var notesText: String = ""
    @State private var showNotesField: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 13))
                Text("Approval Required: \(card.stageName)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Playbook: \(runner.playbook.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text(card.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if !card.proposedActions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proposed Actions:")
                        .font(.system(size: 10, weight: .medium))
                    ForEach(card.proposedActions.prefix(3), id: \.self) { action in
                        Text("• \(action)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }

            if showNotesField {
                TextField("Optional notes or reason...", text: $notesText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
            }

            HStack(spacing: 8) {
                Button {
                    showNotesField.toggle()
                } label: {
                    Label(showNotesField ? "Hide Note" : "Add Note", systemImage: "note.text")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Reject") {
                    botManager.resolvePlaybookApproval(
                        cardId: card.id,
                        approved: false,
                        notes: notesText.isEmpty ? "Rejected by user" : notesText
                    )
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .font(.system(size: 11))

                Button("Approve Stage") {
                    botManager.resolvePlaybookApproval(
                        cardId: card.id,
                        approved: true,
                        notes: notesText.isEmpty ? nil : notesText
                    )
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: 11))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                )
        )
    }
}
