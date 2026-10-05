import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var isUser: Bool { message.role == .user }

    private var accessibilityIdentifierForBubble: String {
        if isUser {
            return "UserMessage_\(message.id.uuidString)"
        }
        return "AgentResponse_\(message.id.uuidString)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 60)
            } else {
                // Agent avatar
                AgentAvatar()
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                // Bubble
                BubbleContent(message: message)
                    .accessibilityIdentifier(accessibilityIdentifierForBubble)
                    .accessibilityLabel(message.content)
                    .accessibilityValue(message.content)

                // Timestamp
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
                    .padding(.horizontal, 4)
            }

            if !isUser {
                Spacer(minLength: 60)
            } else {
                // User avatar
                UserAvatar()
            }
        }
    }
}

// MARK: - Bubble Content

struct BubbleContent: View {
    let message: ChatMessage
    var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if isUser {
                // User message — plain text + optional image attachments
                VStack(alignment: .trailing, spacing: 8) {
                    if !message.attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(0..<message.attachments.count, id: \.self) { idx in
                                Image(nsImage: message.attachments[idx])
                                    .resizable().scaledToFit()
                                    .frame(maxHeight: 160)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    )
                                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                            }
                        }
                    }
                    
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                LinearGradient(
                                    colors: [AppTheme.Palette.accent, Color.blue],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: BubbleShape(isUser: true)
                            )
                    }
                }
            } else {
                // Agent message — markdown content, left-aligned
                VStack(alignment: .leading, spacing: 8) {
                    if let botName = message.botName, !botName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "bolt.badge.automatic.fill")
                                .font(.system(size: 11))
                            Text(botName)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(AppTheme.Palette.accent)
                        .padding(.bottom, 2)
                    }

                    if !message.content.isEmpty {
                        MarkdownText(content: message.content)
                            .textSelection(.enabled)
                    }

                    if message.isStreaming && message.content.isEmpty {
                        TypingIndicator()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(nsColor: .windowBackgroundColor),
                    in: BubbleShape(isUser: false)
                )
                .overlay(
                    BubbleShape(isUser: false)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                )
            }
        }
    }
}

// MARK: - Markdown Text

struct MarkdownText: View {
    let content: String

    var body: some View {
        // Parse and render markdown segments
        VStack(alignment: .leading, spacing: 4) {
            ForEach(parseBlocks(content), id: \.id) { block in
                switch block.type {
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                case .text(let text):
                    Text(makeAttributedString(from: text))
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(text)
                        .accessibilityValue(text)
                        .accessibilityIdentifier("agentBubbleText")
                }
            }
        }
    }

    private func makeAttributedString(from text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: .newlines)
        var inCode = false
        var currentLang = ""
        var codeAccumulator: [String] = []
        var textAccumulator: [String] = []

        for line in lines {
            if line.hasPrefix("```") {
                if inCode {
                    // End code block
                    blocks.append(MarkdownBlock(type: .code(language: currentLang, code: codeAccumulator.joined(separator: "\n"))))
                    codeAccumulator = []
                    currentLang = ""
                    inCode = false
                } else {
                    // Start code block
                    if !textAccumulator.isEmpty {
                        let text = textAccumulator.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            blocks.append(MarkdownBlock(type: .text(text)))
                        }
                        textAccumulator = []
                    }
                    currentLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode {
                codeAccumulator.append(line)
            } else {
                textAccumulator.append(line)
            }
        }

        if inCode && !codeAccumulator.isEmpty {
            blocks.append(MarkdownBlock(type: .code(language: currentLang, code: codeAccumulator.joined(separator: "\n"))))
        } else if !textAccumulator.isEmpty {
            let text = textAccumulator.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(MarkdownBlock(type: .text(text)))
            }
        }

        return blocks
    }
}

// MARK: - Supporting Types

struct MarkdownBlock: Identifiable {
    let id = UUID()
    let type: BlockType

    enum BlockType {
        case text(String)
        case code(language: String, code: String)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copyCode) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailRadius: CGFloat = 4
        let corners = RectangleCornerRadii(
            topLeading: radius,
            bottomLeading: radius,
            bottomTrailing: isUser ? tailRadius : radius,
            topTrailing: isUser ? radius : tailRadius
        )
        return UnevenRoundedRectangle(cornerRadii: corners, style: .continuous).path(in: rect)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { idx in
                Circle()
                    .fill(Color.secondary.opacity(phase == idx ? 1.0 : 0.3))
                    .frame(width: 6, height: 6)
                    .animation(
                        .easeInOut(duration: 0.6)
                        .repeatForever()
                        .delay(Double(idx) * 0.2),
                        value: phase
                    )
            }
        }
        .padding(.vertical, 4)
        .onAppear { phase = 2 }
    }
}

struct AgentAvatar: View {
    var body: some View {
        Circle()
            .fill(AppTheme.Palette.accent.gradient)
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: AppTheme.Palette.accent.opacity(0.3), radius: 4, y: 2)
    }
}

struct UserAvatar: View {
    var body: some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            )
    }
}
