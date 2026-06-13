import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

    var isUser: Bool { message.role == .user }

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
    @State private var isExpanded = true

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
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
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
                                    colors: [Color.purple, Color.blue],
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
                }
            }
        }
    }

    // MARK: Block Parser

    enum BlockType {
        case text(String)
        case code(String, String)
    }

    struct ContentBlock: Identifiable {
        let id = UUID()
        let type: BlockType
    }

    func parseBlocks(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        let pattern = "```(\\w*)\\n([\\s\\S]*?)```"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [ContentBlock(type: .text(content))]
        }

        let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))

        var lastEnd = content.startIndex

        for match in matches {
            // Text before code block
            let matchStart = Range(match.range, in: content)!.lowerBound
            if lastEnd < matchStart {
                let textSegment = String(content[lastEnd..<matchStart])
                if !textSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(ContentBlock(type: .text(textSegment)))
                }
            }

            // Code block
            let langRange = Range(match.range(at: 1), in: content)!
            let codeRange = Range(match.range(at: 2), in: content)!
            let lang = String(content[langRange])
            let code = String(content[codeRange])
            blocks.append(ContentBlock(type: .code(lang, code)))

            lastEnd = Range(match.range, in: content)!.upperBound
        }

        // Remaining text
        if lastEnd < content.endIndex {
            let remaining = String(content[lastEnd...])
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(ContentBlock(type: .text(remaining)))
            }
        }

        if blocks.isEmpty {
            blocks.append(ContentBlock(type: .text(content)))
        }

        return blocks
    }

    func makeAttributedString(from text: String) -> AttributedString {
        // Try to use AttributedString with markdown
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}

// MARK: - Code Block

struct CodeBlock: View {
    let language: String
    let code: String
    @State private var isCopied = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack {
                if !language.isEmpty {
                    Text(language.uppercased())
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    withAnimation { isCopied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        withAnimation { isCopied = false }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied!" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? .green : .secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3))

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.trimmingCharacters(in: .newlines))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}

// MARK: - Bubble Shape

struct BubbleShape: Shape {
    let isUser: Bool
    let radius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        return path
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.purple.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .scaleEffect(animating ? 1.0 : 0.5)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .padding(.vertical, 4)
    }
}

// MARK: - Agent Avatar

struct AgentAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.purple, .blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
            Image(systemName: "bolt.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - User Avatar

struct UserAvatar: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                .frame(width: 32, height: 32)
            Image(systemName: "person.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}
