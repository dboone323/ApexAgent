import Foundation
import FoundationModels
import NaturalLanguage
#if canImport(Translation)
import Translation
#endif

// MARK: - Translate Tool (Apple Translation Framework + NaturalLanguage)

struct TranslateTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    /// Max characters per translation chunk. Stays well under the
    /// TranslationSession and on-device FM prompt budget so no single request
    /// trips either engine.
    private static let maxChunkSize = 2_800
    /// Refuses to load files larger than this (protects context + runtime).
    private static let maxFileSize = 512 * 1_024

    let name = "translate"
    let description = """
    Translates text between languages using Apple's on-device Translation and NaturalLanguage frameworks. \
    Supports automatic source language detection and translation into target languages (e.g. English, Spanish, French, German, Japanese, Chinese). \
    Can also translate entire local files: pass 'filePath' instead of/in addition to 'text' and the whole document will be translated \
    chunk-by-chunk and written to '<original-stem>.<targetlang>.<ext>' next to the source file. Only plain-text-representable files are supported.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The text to translate. Optional if 'filePath' is provided.")
        var text: String?

        @Guide(description: "Path to a local text file whose ENTIRE contents should be translated. The result is written to '<stem>.<targetlang>.<ext>' beside the source file.")
        var filePath: String?

        @Guide(description: "Target language code or name (e.g. 'en', 'es', 'fr', 'de', 'ja', 'zh', 'Spanish', 'French'). Defaults to 'en'.")
        var targetLanguage: String?

        @Guide(description: "Source language code (e.g. 'auto', 'es', 'fr', 'ja'). If omitted or 'auto', automatically detects the language.")
        var sourceLanguage: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            // ── Resolve input: file path takes precedence over inline text ──
            let filePath = arguments.filePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasFilePath = !(filePath ?? "").isEmpty

            var inlineText = arguments.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var sourceURL: URL?

            if hasFilePath {
                let rawPath = filePath!
                let expanded = NSString(string: rawPath).expandingTildeInPath
                let effectivePath: String
                if expanded.hasPrefix("/") {
                    effectivePath = expanded
                } else {
                    let wsPath = await MainActor.run { self.orchestrator.orchestrator.currentWorkspacePath }
                    effectivePath = (wsPath as NSString).appendingPathComponent(expanded)
                }
                let url = URL(fileURLWithPath: effectivePath)
                let fm = FileManager.default
                guard fm.fileExists(atPath: url.path) else {
                    return "❌ Error: File not found at '\(effectivePath)'."
                }
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? Int else {
                    return "❌ Error: Could not stat file '\(effectivePath)'."
                }
                guard size <= Self.maxFileSize else {
                    return "❌ Error: File '\(url.lastPathComponent)' is \(size / 1_024) KB; file translation is capped at \(Self.maxFileSize / 1_024) KB."
                }
                guard let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty else {
                    return "❌ Error: File '\(url.lastPathComponent)' could not be read as UTF-8 text (binary files are not supported)."
                }
                inlineText = contents
                sourceURL = url
            }

            guard !inlineText.isEmpty else {
                return "❌ Error: Provide either 'text' or a readable 'filePath' to translate."
            }

            // ── Detect Source Language ──
            let detectedLanguage = detectLanguage(for: inlineText)
            let srcLangCode = normalizeLanguageCode(arguments.sourceLanguage ?? "") ?? detectedLanguage?.rawValue ?? "en"
            let targetLangCode = normalizeLanguageCode(arguments.targetLanguage ?? "en") ?? "en"

            let srcDisplayName = Locale.current.localizedString(forLanguageCode: srcLangCode) ?? srcLangCode
            let tgtDisplayName = Locale.current.localizedString(forLanguageCode: targetLangCode) ?? targetLangCode

            // ── Perform Translation (chunked) ──
            var translatedText: String?

            #if canImport(Translation)
            if #available(macOS 15.0, *) {
                let sourceLocale = Locale.Language(identifier: srcLangCode)
                let targetLocale = Locale.Language(identifier: targetLangCode)

                do {
                    let session = TranslationSession(installedSource: sourceLocale, target: targetLocale)
                    let chunks = Self.chunkText(inlineText, maxSize: Self.maxChunkSize)
                    var parts: [String] = []
                    parts.reserveCapacity(chunks.count)
                    for chunk in chunks {
                        let response = try await session.translate(chunk)
                        parts.append(response.targetText)
                    }
                    translatedText = parts.joined()
                } catch {
                    // Fallback to local heuristic/LLM translation below
                }
            }
            #endif

            // LLM fallback (per-chunk) if translation session unavailable or threw
            if translatedText == nil {
                let chunks = Self.chunkText(inlineText, maxSize: Self.maxChunkSize)
                var parts: [String] = []
                parts.reserveCapacity(chunks.count)
                for chunk in chunks {
                    parts.append(try await performOrchestratedTranslation(text: chunk, from: srcDisplayName, to: tgtDisplayName))
                }
                translatedText = parts.joined()
            }

            let result = translatedText ?? inlineText

            // ── Inline snippet mode: report both texts directly ──
            guard let sourceURL = sourceURL else {
                return """
                🌐 **Translation Report**:
                • **Source (\(srcDisplayName))**: \(inlineText)
                • **Target (\(tgtDisplayName))**: \(result)
                • **Detected Language**: \(detectedLanguage?.rawValue ?? srcLangCode)
                """
            }

            // ── Whole-file mode: persist result beside source, return summary ──
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension.isEmpty ? "txt" : sourceURL.pathExtension
            let outURL = sourceURL.deletingLastPathComponent()
                .appendingPathComponent("\(stem).\(targetLangCode)")
                .appendingPathExtension(ext)

            do {
                try result.write(to: outURL, atomically: true, encoding: .utf8)
            } catch {
                return "❌ Translation completed but writing '\(outURL.lastPathComponent)' failed: \(error.localizedDescription)\n\nFirst part of translation:\n\(String(result.prefix(800)))"
            }

            let chunkCount = Self.chunkText(inlineText, maxSize: Self.maxChunkSize).count
            let preview = String(result.prefix(800))
            return """
            🌐 **Whole-File Translation Complete**
            • **Source file**: \(sourceURL.lastPathComponent) (\(srcDisplayName))
            • **Translated file**: \(outURL.path) (\(tgtDisplayName))
            • **Chunks translated**: \(chunkCount) · **Characters**: \(result.count)
            • **Detected Language**: \(detectedLanguage?.rawValue ?? srcLangCode)

            **Preview (first 800 chars)**:
            \(preview)
            """
        }
    }

    // MARK: - Text Chunking

    /// Splits text into chunks of at most `maxSize` characters without losing
    /// any characters: chunks reassemble 1:1 via concatenation, preserving
    /// exact newlines/blank lines (and absence of a trailing newline). Splits
    /// preferentially on line breaks; a single line longer than `maxSize` is
    /// hard-split at word boundaries.
    static func chunkText(_ text: String, maxSize: Int) -> [String] {
        precondition(maxSize > 0, "maxSize must be positive")
        guard text.count > maxSize else { return [text] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }
        }

        // Index-based scan keeps each line's own terminator (`\n`) inside the
        // line string, so reassembly is byte-exact even for inputs without a
        // trailing newline or with consecutive newlines.
        var idx = text.startIndex
        while idx < text.endIndex {
            let nl = text[idx...].firstIndex(of: "\n")
            let lineEnd = nl.map { text.index(after: $0) } ?? text.endIndex
            let lineStr = String(text[idx..<lineEnd])
            idx = lineEnd

            if lineStr.count > maxSize {
                flush()
                // Hard-split the oversized line at word boundaries.
                var remainder = Substring(lineStr)
                while remainder.count > maxSize {
                    let cutIndex = remainder.index(remainder.startIndex, offsetBy: maxSize)
                    // Try to break at the last space before the cut.
                    let boundary = remainder[..<cutIndex].lastIndex(of: " ") ?? cutIndex
                    chunks.append(String(remainder[..<boundary]))
                    remainder = remainder[boundary...]
                }
                current = String(remainder)
            } else if current.count + lineStr.count > maxSize {
                flush()
                current = lineStr
            } else {
                current += lineStr
            }
        }
        flush()
        return chunks.filter { !$0.isEmpty }
    }

    // MARK: - Detection & Code Normalization

    private func detectLanguage(for text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    private func normalizeLanguageCode(_ input: String) -> String? {
        let trimmed = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "auto" { return nil }
        if trimmed.count == 2 { return trimmed }

        switch trimmed {
        case "english": return "en"
        case "spanish", "español": return "es"
        case "french", "français": return "fr"
        case "german", "deutsch": return "de"
        case "italian", "italiano": return "it"
        case "portuguese", "português": return "pt"
        case "japanese", "nihongo": return "ja"
        case "chinese", "mandarin": return "zh"
        case "korean": return "ko"
        case "russian": return "ru"
        case "dutch": return "nl"
        case "arabic": return "ar"
        default: return trimmed
        }
    }

    private func performOrchestratedTranslation(text: String, from: String, to: String) async throws -> String {
        // Use the native Foundation Models language engine to perform translation
        let prompt = "Translate the following text from \(from) to \(to). Provide only the direct translation with no commentary:\n\n\(text)"
        let session = await orchestrator.orchestrator.sessionForAgent(
            agent: AgentRegistry.shared.resolve(name: "developer") ?? RegisteredAgent(name: "developer", systemPrompt: "You are a translator.", allowedTools: []),
            preference: .localSystem,
            instructions: "You are a professional translator. Translate accurately and return only the translated text.",
            allowedTools: [],
            toolCallingMode: .disallowed
        )
        let response = try await session.respond(to: Prompt(prompt))
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
