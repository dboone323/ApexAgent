import Foundation
import FoundationModels
import AppKit

// MARK: - Clipboard Read Tool

struct ClipboardReadTool: Tool {
    let name = "read_clipboard"
    let description = "Reads the current text content of the macOS clipboard (pasteboard) and returns it."

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            return await MainActor.run {
                let pasteboard = NSPasteboard.general
                if let text = pasteboard.string(forType: .string) {
                    if text.isEmpty {
                        return "Clipboard is empty (no text content)"
                    }
                    // Truncate very large clipboard content
                    if text.count > 5000 {
                        return "Clipboard content (\(text.count) chars, showing first 5000):\n\n" + String(text.prefix(5000)) + "\n\n[... truncated ...]"
                    }
                    return "Clipboard content:\n\n\(text)"
                } else {
                    // Check what types are available
                    let types = pasteboard.types?.map { $0.rawValue }.joined(separator: ", ") ?? "none"
                    return "No text in clipboard. Available types: \(types)"
                }
            }
        }
    }
}

// MARK: - Clipboard Write Tool

struct ClipboardWriteTool: Tool {
    let name = "write_clipboard"
    let description = "Sets the macOS clipboard (pasteboard) to the specified text content."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The text to copy to the clipboard")
        var text: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            return await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(arguments.text, forType: .string)
                return "✅ Copied \(arguments.text.count) characters to clipboard"
            }
        }
    }
}
