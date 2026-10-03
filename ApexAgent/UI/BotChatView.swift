import SwiftUI
import AppKit

// MARK: - BotChatView: Interactive chat with a persistent Bot teammate

/// Presents the full conversation history, streaming responses, tool approval
/// cards, system prompt inspector, and memory editor for a single Bot.
struct BotChatView: View {
    @Bindable var session: BotSession
    @Environment(BotManager.self) private var botManager
    @State private var inputText: String = ""
    @State private var isShowingPromptInspector = false
    @State private var isShowingMemoryEditor = false
    @State private var approvalNotes: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Bot header
            BotChatHeader(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            
            // Playbook approval card banner (when a stage requires human-in-the-loop approval)
            if let card = botManager.activePlaybookRunner?.pendingApprovalCard {
                PlaybookApprovalBannerView(
                    card: card,
                    notes: $approvalNotes,
                    onApprove: {
                        let cleanNotes = approvalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = botManager.resolvePlaybookApproval(
                            approved: true,
                            notes: cleanNotes.isEmpty ? nil : cleanNotes
                        )
                        approvalNotes = ""
                    },
                    onReject: {
                        let cleanNotes = approvalNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                        _ = botManager.resolvePlaybookApproval(
                            approved: false,
                            notes: cleanNotes.isEmpty ? "Rejected by user" : cleanNotes
                        )
                        approvalNotes = ""
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider()

            // Message scroll area
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
                    }
                    .padding(16)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input bar
            BotChatInputBar(
                session: session,
                inputText: $inputText,
                isInputFocused: $isInputFocused
            )
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    isShowingPromptInspector.toggle()
                } label: {
                    Label("Instructions", systemImage: "doc.text")
                }
                .popover(isPresented: $isShowingPromptInspector) {
                    BotPromptInspectorView(bot: session.bot)
                        .frame(width: 360, height: 280)
                }

                Button {
                    isShowingMemoryEditor.toggle()
                } label: {
                    Label("Memory", systemImage: "brain.head.profile")
                }
                .popover(isPresented: $isShowingMemoryEditor) {
                    BotMemoryEditorView(bot: session.bot)
                        .frame(width: 380, height: 320)
                }

                Menu {
                    Button("Clear History", role: .destructive) {
                        session.reset()
                    }
                    Button("Duplicate Bot") {
                        _ = botManager.duplicateBot(session.bot)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}

// MARK: - Playbook Approval Banner View

struct PlaybookApprovalBannerView: View {
    let card: PlaybookApprovalCard
    @Binding var notes: String
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.orange)
                Text("Stage Approval Required: \(card.stageTitle)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }

            if !card.summary.isEmpty {
                Text(card.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            TextField("Resolution notes or instructions (optional)...", text: $notes)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))

            HStack(spacing: 8) {
                Spacer()
                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Bot Chat Header

struct BotChatHeader: View {
    @Bindable var session: BotSession
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: session.bot.avatarName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
            }
            
            // Name and title
            VStack(alignment: .leading, spacing: 2) {
                Text(session.bot.name)
                    .font(.system(size: 15, weight: .semibold))
                if !session.bot.title.isEmpty {
                    Text(session.bot.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer()
            
            // Model badge
            HStack(spacing: 4) {
                Circle()
                    .fill(session.modelAvailability == .available ? .green : .red)
                    .frame(width: 6, height: 6)
                Text(modelLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
        }
    }
    
    private var modelLabel: String {
        switch session.effectiveModelProvider {
        case .autoPicker: return "Auto"
        case .appleOnDevice: return "AFM 3"
        case .applePCC: return "PCC"
        case .cloudGemini: return "Gemini"
        case .localOllama: return "Ollama"
        case .localMLX: return "MLX"
        case .fmCLI: return "CLI"
        }
    }
}

// MARK: - Bot Welcome View

struct BotWelcomeView: View {
    @Bindable var session: BotSession
    
    let suggestions: [(String, String)] = [
        ("terminal.fill", "What's using the most disk space?"),
        ("safari.fill", "Search the web for WWDC 2026 highlights"),
        ("swift", "Review recent Swift commits"),
        ("folder.fill", "List files in ~/Developer")
    ]
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: session.bot.avatarName)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
            }
            
            VStack(spacing: 4) {
                Text(session.bot.name)
                    .font(.title2.weight(.semibold))
                if !session.bot.title.isEmpty {
                    Text(session.bot.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !session.bot.descriptionText.isEmpty {
                    Text(session.bot.descriptionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 32)
                }
            }
            
            // Suggestion chips
            VStack(spacing: 8) {
                Text("Try asking:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                
                ForEach(suggestions, id: \.1) { icon, prompt in
                    Button {
                        session.sendMessage(prompt)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(prompt)
                                .font(.system(size: 12))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 380)
            .padding(.top, 8)
        }
    }
}

// MARK: - Bot Message Row

struct BotMessageRow: View {
    let message: ChatMessage
    let bot: BotProfile
    @Environment(\.colorScheme) private var colorScheme
    
    var isUser: Bool { message.role == .user }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer()
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
                .padding(.top, 2)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                // Sender label
                if !isUser {
                    Text(bot.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                
                // Attachments preview if present
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(0..<message.attachments.count, id: \.self) { idx in
                            Image(nsImage: message.attachments[idx])
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))
                        }
                    }
                    .padding(.bottom, 2)
                }

                // Message bubble
                HStack {
                    if message.isStreaming && message.content.isEmpty {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Thinking...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    } else {
                        MarkdownText(content: message.content)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
                .background(bubbleBackground)
                .cornerRadius(12)
                .frame(maxWidth: 540, alignment: isUser ? .trailing : .leading)
            }
            
            if !isUser {
                Spacer()
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
    @Bindable var session: BotSession
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
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                    )
                                Button {
                                    session.pendingAttachments.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.white, Color.black.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 4, y: -4)
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.top, 4)
                }
            }
            
            HStack(alignment: .center, spacing: 8) {
                // Photo upload button
                Button {
                    attachImageFile()
                } label: {
                    Image(systemName: session.pendingAttachments.isEmpty ? "photo" : "photo.badge.checkmark")
                        .font(.system(size: 14))
                        .foregroundStyle(session.pendingAttachments.isEmpty ? .secondary : AppTheme.Palette.accent)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 28)
                .help("Attach image")

                TextField(session.isGenerating ? "Queue next prompt..." : "Message \(session.bot.name)...", text: $inputText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($isInputFocused)
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

// MARK: - Bot Prompt Inspector View

struct BotPromptInspectorView: View {
    let bot: BotProfile
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                Text("\(bot.name) Instructions")
                    .font(.headline)
            }
            
            Divider()
            
            ScrollView {
                Text(bot.systemInstructions)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
    }
}

// MARK: - Bot Memory Editor View

struct BotMemoryEditorView: View {
    @Bindable var bot: BotProfile
    @Environment(\.dismiss) private var dismiss
    @State private var memoryText: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(Color.accentColor)
                Text("\(bot.name) Memory")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    bot.memory = memoryText
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            
            Text("Working context, style rules, and facts this Bot retains across conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextEditor(text: $memoryText)
                .font(.system(size: 12, design: .monospaced))
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        }
        .padding(14)
        .onAppear {
            memoryText = bot.memory
        }
    }
}
