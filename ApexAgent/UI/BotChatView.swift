import SwiftUI
import AppKit
import FoundationModels

// MARK: - Bot Chat View

/// Displays the chat for a specific Bot session. Resembles ChatView but
/// driven by a BotSession instead of the global orchestrator.
struct BotChatView: View {
    @Bindable var session: BotSession
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Bot header
            BotChatHeader(session: session)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            
            // Generation state banner
            if session.isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating...")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.accent)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(AppTheme.Palette.accent.opacity(0.06))
                .overlay(
                    Rectangle()
                        .fill(AppTheme.Palette.accent.opacity(0.2))
                        .frame(height: 0.5),
                    alignment: .bottom
                )
            }
            
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if session.messages.isEmpty {
                            BotWelcomeView(session: session)
                                .padding(.top, 80)
                                .allowsHitTesting(!session.isGenerating)
                        } else {
                            ForEach(session.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                                    .opacity(message.isStreaming ? 0.7 : 1.0)
                            }
                        }
                        
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .allowsHitTesting(!session.isGenerating)
                }
                .accessibilityLabel("Conversation messages list")
                .accessibilityIdentifier("conversationScrollView")
                .onChange(of: session.messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: session.messages.last?.content) {
                    scrollToBottom(proxy: proxy)
                }
            }
            
            Divider()
            
            // Input area
            BotChatInputBar(
                session: session,
                inputText: $inputText,
                isInputFocused: $isInputFocused
            )
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { isInputFocused = true }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Bot Chat Header

struct BotChatHeader: View {
    @Bindable var session: BotSession
    
    var body: some View {
        HStack(spacing: 10) {
            // Avatar
            Image(systemName: session.bot.avatarName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [AppTheme.Palette.accent, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
            
            // Name + title
            VStack(alignment: .leading, spacing: 1) {
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
        switch session.modelPreference {
        case .autoPicker: return "Auto"
        case .localSystem: return "AFM 3"
        case .privateCloud: return "PCC"
        case .cloudGemini: return "Gemini"
        case .localOllama: return "Ollama"
        case .localMLX: return "MLX"
        case .hybrid: return "Hybrid"
        }
    }
}

// MARK: - Bot Welcome View

struct BotWelcomeView: View {
    @Bindable var session: BotSession
    
    let suggestions: [(String, String)] = [
        ("terminal.fill", "What's using the most disk space?"),
        ("safari.fill", "Search the web for WWDC 2026 highlights"),
        ("folder.fill", "List my Downloads folder"),
        ("applescript.fill", "Open the Calculator app"),
    ]
    
    var body: some View {
        VStack(spacing: 24) {
            // Logo
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AppTheme.Palette.accent, .blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 56, height: 56)
                    
                    Image(systemName: session.bot.avatarName)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: AppTheme.Palette.accent.opacity(0.4), radius: 12, y: 6)
                
                VStack(spacing: 2) {
                    Text(session.bot.name)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(session.bot.title.isEmpty ? "Your AI teammate" : session.bot.title)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            
            // Description
            if !session.bot.descriptionText.isEmpty {
                Text(session.bot.descriptionText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            
            // Suggestions
            VStack(spacing: 8) {
                Text("Try asking:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                
                ForEach(suggestions, id: \.1) { icon, text in
                    SuggestionChip(icon: icon, text: text, color: AppTheme.Palette.accent) {
                        session.sendMessage(text)
                    }
                }
            }
        }
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Bot Chat Input Bar

struct BotChatInputBar: View {
    @Bindable var session: BotSession
    @Binding var inputText: String
    @FocusState.Binding var isInputFocused: Bool
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pending attachments
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<session.pendingAttachments.count, id: \.self) { idx in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: session.pendingAttachments[idx])
                                    .resizable().scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                Button {
                                    session.pendingAttachments.remove(at: idx)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.gray, Color(nsColor: .windowBackgroundColor))
                                        .font(.system(size: 14))
                                }
                                .buttonStyle(.plain)
                                .offset(x: 5, y: -5)
                            }
                            .padding(.top, 5)
                            .padding(.trailing, 5)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 62)
            }
            
            HStack(alignment: .bottom, spacing: 10) {
                // Attachment buttons
                HStack(spacing: 6) {
                    Button {
                        attachImageFile()
                    } label: {
                        Image(systemName: "photo")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                            .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Attach Image file")
                    .accessibilityIdentifier("attachImageButton")
                    .accessibilityLabel("Attach image file")
                    
                    Button {
                        Task {
                            let countBefore = session.orchestrator?.pendingAttachments.count ?? 0
                            await session.orchestrator?.captureAndAttachScreenshot()
                            let countAfter = session.orchestrator?.pendingAttachments.count ?? 0
                            if countAfter > countBefore,
                               let photo = session.orchestrator?.pendingAttachments.removeLast() {
                                session.pendingAttachments.append(photo)
                            }
                        }
                    } label: {
                        Image(systemName: "camera")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                            .overlay(Circle().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Take and attach Screenshot")
                    .accessibilityIdentifier("attachScreenshotButton")
                    .accessibilityLabel("Attach screenshot")
                }
                
                // Text input
                ZStack(alignment: .bottomLeading) {
                    if inputText.isEmpty {
                        Text("Message \(session.bot.name)...")
                            .foregroundStyle(.quaternary)
                            .font(.system(size: 14))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    
                    TextEditor(text: $inputText)
                        .font(.system(size: 14))
                        .frame(minHeight: 36, maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)
                        .scrollContentBackground(.hidden)
                        .focused($isInputFocused)
                        .accessibilityIdentifier("chatInputField")
                        .onKeyPress(.return) {
                            if NSEvent.modifierFlags.contains(.shift) {
                                inputText += "\n"
                                return .handled
                            } else {
                                send()
                                return .handled
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(isInputFocused ? AppTheme.Palette.accent.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .shadow(color: isInputFocused ? AppTheme.Palette.accent.opacity(0.1) : .clear, radius: 6)
                )
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        if provider.canLoadObject(ofClass: URL.self) {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                if let url = url, let image = NSImage(contentsOf: url) {
                                    DispatchQueue.main.async {
                                        session.pendingAttachments.append(image)
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                .onKeyPress(phases: .down) { keyPress in
                    if keyPress.key == "v" && keyPress.modifiers.contains(.command) {
                        return checkPasteboardAndPaste()
                    }
                    return .ignored
                }
                
                // Send/Stop button
                if session.isGenerating {
                    Button(action: {
                        session.orchestrator?.cancelGeneration()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.red.opacity(0.15))
                                .frame(width: 38, height: 38)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Stop generation")
                    .accessibilityIdentifier("stopGenerationButton")
                    .accessibilityLabel("Stop generation")
                } else {
                    Button(action: send) {
                        ZStack {
                            Circle()
                                .fill(
                                    (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingAttachments.isEmpty)
                                        ? AnyShapeStyle(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                                        : AnyShapeStyle(LinearGradient(colors: [AppTheme.Palette.accent, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                                .frame(width: 38, height: 38)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sendButton")
                    .accessibilityLabel("Send message")
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && session.pendingAttachments.isEmpty)
                    .help("Send message (Return)")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }
    
    private func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !session.pendingAttachments.isEmpty else { return }
        guard !session.isGenerating else { return }
        inputText = ""
        session.sendMessage(text)
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
