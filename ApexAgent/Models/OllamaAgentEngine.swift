import Foundation
import AppKit

// MARK: - Ollama Agent Engine
//
// Direct integration with local Ollama daemon for complete local autonomy,
// multi-step tool calling loop, and streaming response delivery.
// Respects role-based model tiers (fast 3B for general chat / Apex, specialized
// 7B/12B coding & research models for deep dive bots).

@MainActor
final class OllamaAgentEngine: AgentEngine {
    static let shared = OllamaAgentEngine()

    weak var orchestrator: AgentOrchestrator?

    init(orchestrator: AgentOrchestrator? = nil) {
        self.orchestrator = orchestrator
    }

    /// Builds a user message dictionary compatible with Ollama multimodal chat completions.
    static func buildUserMessage(prompt: String, attachments: [NSImage] = []) -> [String: Any] {
        var msg: [String: Any] = [
            "role": "user",
            "content": prompt
        ]
        let base64Images = attachments.compactMap { img -> String? in
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            return png.base64EncodedString()
        }
        if !base64Images.isEmpty {
            msg["images"] = base64Images
        }
        return msg
    }

    /// Extracts JSON-structured fallback tool calls from model output when running with small or quantised models.
    static func extractFallbackToolCalls(from text: String, availableToolNames: Set<String>) -> [[String: Any]] {
        var results: [[String: Any]] = []
        let pattern = #"\{[\s\r\n]*"name"[\s\r\n]*:[\s\r\n]*"([^"]+)"[\s\r\n]*,[\s\r\n]*"arguments"[\s\r\n]*:[\s\r\n]*(\{.*?\})[\s\r\n]*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return results
        }
        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let name = nsString.substring(with: match.range(at: 1))
            let argsStr = nsString.substring(with: match.range(at: 2))
            if availableToolNames.contains(name) {
                let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8))) as? [String: Any] ?? [:]
                results.append([
                    "function": [
                        "name": name,
                        "arguments": args
                    ]
                ])
            }
        }
        return results
    }

    /// AgentEngine protocol conformance
    func streamResponse(
        prompt: String,
        attachments: [NSImage] = [],
        history: [ChatMessage] = [],
        instructions: String = "",
        toolCallingMode: AgentToolCallingMode = .auto,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        guard let orch = orchestrator else { return }
        _ = try await executeTurn(
            prompt: prompt,
            bot: nil,
            instructions: instructions,
            allowedTools: nil,
            toolCallingMode: toolCallingMode,
            orchestrator: orch,
            onUpdate: { str in
                Task { @MainActor in
                    onUpdate(str)
                }
            }
        )
    }

    /// Executes an agent turn with tool calling loops against Ollama.
    func executeTurn(
        prompt: String,
        bot: BotProfile? = nil,
        instructions: String = "",
        allowedTools: [String]? = nil,
        toolCallingMode: AgentToolCallingMode = .auto,
        orchestrator: AgentOrchestrator,
        onUpdate: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let hostStr = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
        guard let host = URL(string: hostStr) else {
            throw NSError(domain: "OllamaAgentEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama Host URL: \(hostStr)"])
        }

        let selectedModel = ModelRegistry.ollamaModel(for: bot, role: bot?.title, prompt: prompt)
        let endpoint = host.appendingPathComponent("api/chat")

        var messages: [[String: Any]] = []

        // System instructions
        let effectiveInstructions = instructions.isEmpty ? (bot?.systemInstructions ?? "") : instructions
        if !effectiveInstructions.isEmpty {
            messages.append([
                "role": "system",
                "content": effectiveInstructions
            ])
        }

        // Add user prompt
        messages.append([
            "role": "user",
            "content": prompt
        ])

        // Build tool schemas if enabled
        let toolsSchema = (toolCallingMode != .disabled) ? getParsedSchemas() : []
        let filteredTools: [[String: Any]]
        if let allowed = allowedTools {
            let allowedSet = Set(allowed)
            filteredTools = toolsSchema.filter { dict in
                guard let funcDict = dict["function"] as? [String: Any],
                      let name = funcDict["name"] as? String else { return false }
                return allowedSet.contains(name)
            }
        } else {
            filteredTools = toolsSchema
        }

        var fullResponse = ""
        var loopCount = 0
        let maxLoops = 6
        var lastToolOutput = ""
        var disableToolsOnNextTurn = false

        ModelRegistry.unloadPreviousOllamaModelIfNeeded(newModel: selectedModel)

        while loopCount < maxLoops {
            loopCount += 1

            var payload: [String: Any] = [
                "model": selectedModel,
                "messages": messages,
                "stream": true,
                "keep_alive": "2m",
                "options": [
                    "temperature": 0.3,
                    "num_ctx": 8192
                ]
            ]

            if !filteredTools.isEmpty && !disableToolsOnNextTurn {
                payload["tools"] = filteredTools
            }

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.addValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            request.timeoutInterval = 90

            let (stream, response) = try await URLSession.shared.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "OllamaAgentEngine", code: code, userInfo: [NSLocalizedDescriptionKey: "Ollama returned HTTP \(code)"])
            }

            var currentTurnText = ""
            var toolCalls: [[String: Any]] = []

            for try await line in stream.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let msg = json["message"] as? [String: Any] else { continue }

                if let content = msg["content"] as? String, !content.isEmpty {
                    currentTurnText += content
                    fullResponse += content
                    onUpdate?(fullResponse)
                }

                if let calls = msg["tool_calls"] as? [[String: Any]] {
                    toolCalls.append(contentsOf: calls)
                }
            }

            // Fallback tool call extraction if native tool_calls were not parsed
            if toolCalls.isEmpty && !filteredTools.isEmpty {
                let availableNames = Set(filteredTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
                toolCalls = Self.extractFallbackToolCalls(from: currentTurnText, availableToolNames: availableNames)
            }

            // If no tool calls were emitted, we are done
            if toolCalls.isEmpty {
                break
            }

            // Append assistant response to transcript with tool calls
            messages.append([
                "role": "assistant",
                "content": currentTurnText,
                "tool_calls": toolCalls
            ])

            // Execute each tool call
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let args = (function["arguments"] as? [String: Any]) ?? [:]

                let rawArgs = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                if ProcessInfo.processInfo.arguments.contains("--cli") {
                    AppLog.info(.engine, "\n⚙️ [Tool Call]: \(name)(\(rawArgs))")
                }

                let toolOutput: String
                do {
                    toolOutput = try await orchestrator.executeToolByName(
                        name: name,
                        jsonArguments: rawArgs,
                        bot: bot,
                        agentIdentity: bot.map { AgentIdentity.bot(id: $0.id, name: $0.name) }
                    )
                } catch {
                    toolOutput = "ERROR: Tool '\(name)' failed: \(error.localizedDescription)"
                }

                if ProcessInfo.processInfo.arguments.contains("--cli") {
                    AppLog.info(.engine, "✅ [Tool Output]: \(toolOutput.prefix(300))\n")
                }

                lastToolOutput = toolOutput
                messages.append([
                    "role": "tool",
                    "content": toolOutput,
                    "name": name
                ])
            }

            // If a terminal / high-context tool produced an answer (like web_search or read_file),
            // disable tools on next loop so the model focuses on synthesizing
            if toolCalls.contains(where: {
                let n = (($0["function"] as? [String: Any])?["name"] as? String) ?? ""
                return n == "web_search" || n == "search_memory" || n == "read_file" || n == "ask_bot"
            }) {
                disableToolsOnNextTurn = true
            }
        }

        return fullResponse.isEmpty ? lastToolOutput : fullResponse
    }
}

// MARK: - Ollama Streaming Engine Protocol Conformance

@MainActor
struct OllamaStreamingEngine: AgentEngine {
    let orchestrator: AgentOrchestrator
    var bot: BotProfile?
    var allowedTools: [String]?

    func streamResponse(
        prompt: String,
        attachments: [NSImage] = [],
        history: [ChatMessage] = [],
        instructions: String = "",
        toolCallingMode: AgentToolCallingMode = .auto,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        _ = try await OllamaAgentEngine.shared.executeTurn(
            prompt: prompt,
            bot: bot,
            instructions: instructions,
            allowedTools: allowedTools,
            toolCallingMode: toolCallingMode,
            orchestrator: orchestrator,
            onUpdate: { str in
                Task { @MainActor in
                    onUpdate(str)
                }
            }
        )
    }
}
