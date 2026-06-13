import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

struct ChatView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @State private var inputText = ""
    @State private var scrollProxy: ScrollViewProxy?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if orchestrator.messages.isEmpty {
                            WelcomeView()
                                .padding(.top, 80)
                        } else {
                            ForEach(orchestrator.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        // Bottom anchor for auto-scroll
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: orchestrator.messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: orchestrator.messages.last?.content) {
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // Input area
            ChatInputBar(inputText: $inputText, isInputFocused: $isInputFocused)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { isInputFocused = true }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
}

// MARK: - Welcome View

struct WelcomeView: View {
    @Environment(AgentOrchestrator.self) private var orchestrator

    let suggestions: [(String, String, Color)] = [
        ("terminal.fill", "What's using the most disk space?", .purple),
        ("safari.fill", "Search the web for WWDC 2026 highlights", .blue),
        ("folder.fill", "List my Downloads folder", .orange),
        ("applescript.fill", "Open the Calculator app", .green),
    ]

    var body: some View {
        VStack(spacing: 32) {
            // Logo
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.purple, .blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 72, height: 72)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: .purple.opacity(0.4), radius: 16, y: 8)

                VStack(spacing: 4) {
                    Text("Apex Agent")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    Text("Your local AI assistant — powered by Apple Foundation Models")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            // Suggestion chips
            VStack(spacing: 10) {
                Text("Try asking:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)

                ForEach(suggestions, id: \.1) { icon, text, color in
                    SuggestionChip(icon: icon, text: text, color: color) {
                        orchestrator.sendMessage(text)
                    }
                }
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }
}

struct SuggestionChip: View {
    let icon: String
    let text: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.1) : Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .frame(maxWidth: 440)
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Environment(AgentOrchestrator.self) private var orchestrator
    @Binding var inputText: String
    @FocusState.Binding var isInputFocused: Bool
    @State private var isHovered = false
    @StateObject private var voiceController = VoiceController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Pending attachments thumbnails preview
            if !orchestrator.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<orchestrator.pendingAttachments.count, id: \.self) { idx in
                            ZStack(alignment: .topTrailing) {
                                Image(nsImage: orchestrator.pendingAttachments[idx])
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 52, height: 52)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                                
                                Button {
                                    orchestrator.pendingAttachments.remove(at: idx)
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
                // Attachments button
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

                    Button {
                        Task {
                            await orchestrator.captureAndAttachScreenshot()
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

                    Button {
                        toggleRecording()
                    } label: {
                        Image(systemName: voiceController.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 15))
                            .foregroundStyle(voiceController.isRecording ? .red : .secondary)
                            .frame(width: 28, height: 28)
                            .background(voiceController.isRecording ? Color.red.opacity(0.15) : Color(nsColor: .controlBackgroundColor), in: Circle())
                            .overlay(Circle().stroke(voiceController.isRecording ? Color.red.opacity(0.5) : Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(voiceController.isRecording ? "Stop recording" : "Start recording (Speech-to-Text)")
                }

                // Text input
                ZStack(alignment: .bottomLeading) {
                    if inputText.isEmpty {
                        Text("Message Apex...")
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
                                .stroke(isInputFocused ? Color.purple.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .shadow(color: isInputFocused ? .purple.opacity(0.1) : .clear, radius: 6)
                )
                // Drop Destination for Drag & Drop support
                .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        if provider.canLoadObject(ofClass: URL.self) {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                if let url = url, let image = NSImage(contentsOf: url) {
                                    DispatchQueue.main.async {
                                        orchestrator.pendingAttachments.append(image)
                                    }
                                }
                            }
                        } else if provider.canLoadObject(ofClass: NSImage.self) {
                            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                                if let image = image as? NSImage {
                                    DispatchQueue.main.async {
                                        orchestrator.pendingAttachments.append(image)
                                    }
                                }
                            }
                        }
                    }
                    return true
                }
                // Pasteboard Paste Support (⌘V) on keypress
                .onKeyPress(phases: .down) { keyPress in
                    if keyPress.key == "v" && keyPress.modifiers.contains(.command) {
                        return checkPasteboardAndPaste()
                    }
                    return .ignored
                }

                // Send / Cancel button
                if orchestrator.isGenerating {
                    Button(action: { orchestrator.cancelGeneration() }) {
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
                } else {
                    Button(action: send) {
                        ZStack {
                            Circle()
                                .fill(
                                    (inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && orchestrator.pendingAttachments.isEmpty)
                                    ? AnyShapeStyle(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                                    : AnyShapeStyle(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                                )
                                .frame(width: 38, height: 38)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && orchestrator.pendingAttachments.isEmpty)
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
        guard !text.isEmpty || !orchestrator.pendingAttachments.isEmpty else { return }
        guard !orchestrator.isGenerating else { return }
        inputText = ""
        orchestrator.sendMessage(text)
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
                    orchestrator.pendingAttachments.append(image)
                }
            }
        }
    }

    private func checkPasteboardAndPaste() -> KeyPress.Result {
        let pb = NSPasteboard.general
        
        // 1. Direct Image Data (TIFF/PNG)
        if let tiff = pb.data(forType: .tiff), let image = NSImage(data: tiff) {
            orchestrator.pendingAttachments.append(image)
            return .handled
        }
        if let png = pb.data(forType: .png), let image = NSImage(data: png) {
            orchestrator.pendingAttachments.append(image)
            return .handled
        }
        
        // 2. File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            var imageAttached = false
            for url in urls {
                if let image = NSImage(contentsOf: url) {
                    orchestrator.pendingAttachments.append(image)
                    imageAttached = true
                }
            }
            if imageAttached {
                return .handled
            }
        }
        
        return .ignored
    }

    private func toggleRecording() {
        if voiceController.isRecording {
            voiceController.stopRecording()
        } else {
            Task {
                let granted = await voiceController.requestPermissions()
                if granted {
                    do {
                        try voiceController.startRecording { transcription in
                            inputText = transcription
                        }
                    } catch {
                        print("Failed to start voice recording: \(error)")
                    }
                } else {
                    print("Speech/Microphone permissions denied.")
                }
            }
        }
    }
}
