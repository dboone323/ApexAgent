import Foundation
import AppKit

// MARK: - Ollama Agent Engine (direct HTTP, bypasses FoundationModels channel)
//
// The on-device FoundationModels `LanguageModelExecutorGenerationChannel` pump
// crashes (SIGSEGV) on macOS 27.0 build 26A5388g — the same beta-skew class as
// the `Attachment` launch crash. ApexAgent's `LocalOllamaLanguageModel` still
// conforms to `LanguageModel`/`LanguageModelExecutor` (per WWDC26 session 339,
// "Bring an LLM provider to the Foundation Models framework") for when the OS
// is fixed, but on THIS build that path cannot stream. This engine talks to
// Ollama directly over its local HTTP `/api/chat` endpoint and runs tools
// through the existing `allTools`/`executeWithLogging` pipeline (confirmation
// gate + indirect-prompt-injection sanitizer), so the Local Ollama provider
// functions end-to-end today.

@MainActor
struct OllamaAgentEngine: AgentEngine {
    let orchestrator: AgentOrchestrator
    /// Per-bot Ollama model override. When set, this bot's
    /// `ollamaModelOverride` takes priority over the global default.
    var bot: BotProfile?
    /// Optional allowed tool names. When set (e.g. for a delegated sub-agent),
    /// only tools in this list are offered to the model or permitted for execution.
    var allowedTools: [String]?

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let hostString = UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434"
        guard let baseURL = URL(string: hostString) else {
            throw NSError(domain: "OllamaAgentEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama host URL: \(hostString)"])
        }
        // Default to gemma4:12b when unset: a strong local model for Apple
        // Silicon on macOS 27 (Gemma 4 family, ~7.6GB). Falls back to a clear
        // "model not pulled" error from Ollama if it isn't available.
        // Per-bot override takes priority when set.
        let model: String
        if let botOverride = bot?.ollamaModelOverride,
           !botOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model = botOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            model = ModelRegistry.ollamaModel()
        }
        let useTools = toolCallingMode != .disabled

        // Map history + system instructions + new prompt into Ollama messages.
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        for msg in history {
            let role: String = switch msg.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            }
            var entry: [String: Any] = ["role": role, "content": msg.content]
            if !msg.attachments.isEmpty {
                let historyImages = msg.attachments.compactMap { base64String(from: $0) }
                if !historyImages.isEmpty {
                    entry["images"] = historyImages
                }
            }
            messages.append(entry)
        }
        messages.append(Self.buildUserMessage(prompt: prompt, attachments: attachments))

        // Build Ollama function-tool schemas from the live tool registry.
        let allSchemas = getParsedSchemas()
        let effectiveAllowed: Set<String>? = if let allowed = allowedTools {
            Set(allowed)
        } else if useTools {
            Set(IntentToolSelector.selectRelevantToolNames(for: prompt, allSchemas: allSchemas))
        } else {
            nil
        }

        var tools: [[String: Any]] = []
        var availableToolNames = Set<String>()
        if useTools {
            for schema in allSchemas {
                guard let name = schema["name"] as? String else { continue }
                availableToolNames.insert(name)
                if let allowed = effectiveAllowed, !allowed.contains(name) {
                    continue
                }
                tools.append(["type": "function", "function": schema])
            }
        }

        let reasoningBudget = UserDefaults.standard.string(forKey: "apex.reasoningBudget") ?? "off"
        let enableThinking = reasoningBudget != "off" && reasoningBudget != "none" && toolCallingMode != .disabled

        var accumulated = ""
        var lastToolOutput = ""
        let maxLoops = 8
        var disableToolsOnNextTurn = false
        for loop in 0..<maxLoops {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": true,
                "think": enableThinking,
                "options": [
                    "num_ctx": 16384
                ]
            ]
            if !tools.isEmpty && !disableToolsOnNextTurn && loop < maxLoops - 1 {
                body["tools"] = tools
            }

            guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
                throw NSError(domain: "OllamaAgentEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Ollama request."])
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody
            request.timeoutInterval = 300

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch {
                throw NSError(domain: "OllamaAgentEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot reach Ollama at \(baseURL.absoluteString). Start Ollama (ollama serve) and ensure '\(model)' is pulled. (\(error.localizedDescription))"])
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "OllamaAgentEngine", code: -4, userInfo: [NSLocalizedDescriptionKey: "Ollama returned HTTP \(code). Is the model '\(model)' pulled? Try: ollama pull \(model)"])
            }

            var loopText = ""
            var thinkingText = ""
            var toolCalls: [[String: Any]] = []
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                guard let message = json["message"] as? [String: Any] else { continue }
                if let thinking = (message["thinking"] as? String) ?? (message["reasoning"] as? String), !thinking.isEmpty {
                    thinkingText += thinking
                    if accumulated.isEmpty {
                        onUpdate("🧠 *Thinking...*\n\n\(thinkingText)")
                    }
                    if ProcessInfo.processInfo.arguments.contains("--cli") {
                        print(thinking, terminator: "")
                        fflush(stdout)
                    }
                }
                if let content = message["content"] as? String, !content.isEmpty {
                    loopText += content
                    accumulated += content
                    onUpdate(accumulated)
                    if ProcessInfo.processInfo.arguments.contains("--cli") {
                        print(content, terminator: "")
                        fflush(stdout)
                    }
                }
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    toolCalls.append(contentsOf: calls)
                }
            }

            // Fallback parser for 7B/8B models (e.g. qwen2.5-coder:7b) that emit raw JSON tool calls in message.content
            if toolCalls.isEmpty && useTools && !disableToolsOnNextTurn && loop < maxLoops - 1 {
                let recovered = Self.extractFallbackToolCalls(from: loopText, availableToolNames: availableToolNames)
                if !recovered.isEmpty {
                    toolCalls = recovered
                    // Strip the raw JSON tool call from accumulated user-facing text
                    if accumulated.hasSuffix(loopText) {
                        accumulated = String(accumulated.dropLast(loopText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        onUpdate(accumulated)
                    }
                    loopText = ""
                } else if loop == 0 && tools.count == 1,
                          let singleFunc = tools.first?["function"] as? [String: Any],
                          let singleName = singleFunc["name"] as? String {
                    let params = singleFunc["parameters"] as? [String: Any]
                    let requiredParams = (params?["required"] as? [String]) ?? []
                    let promptLower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    let explicitlyRequestedSingleTool = promptLower.contains(singleName.lowercased())
                        && (promptLower.hasPrefix("call ") || promptLower.hasPrefix("use ") || promptLower.hasPrefix("run "))
                    if explicitlyRequestedSingleTool && requiredParams.isEmpty {
                        toolCalls = [[
                            "id": UUID().uuidString,
                            "function": [
                                "name": singleName,
                                "arguments": [String: Any]()
                            ]
                        ]]
                        accumulated = ""
                        loopText = ""
                    }
                }
            }

            // No tool calls -> final answer, we're done (unless it hallucinated future delegation or tool narration without calling tools)
            if toolCalls.isEmpty {
                let lower = loopText.lowercased()
                let canDelegate = allowedTools == nil || allowedTools?.contains("delegate_task") == true
                let announcesFutureDelegation = loop == 0 && useTools && (
                    (canDelegate && (
                        lower.contains("will now delegate")
                        || lower.contains("delegate these tasks")
                        || lower.contains("i will delegate")
                        || lower.contains("proceed to delegate")
                        || lower.contains("delegating these tasks")
                        || lower.contains("performing a deep-dive")
                        || lower.contains("currently mapping")
                        || lower.contains("mapping & analysis phase")
                        || lower.contains("has initiated a multi-dimensional audit")
                        || lower.contains("active audit progress")
                        || lower.contains("i am monitoring their progress")
                        || lower.contains("once they have completed their respective segments")
                        || lower.contains("auditing the \"trust boundaries\"")
                        || lower.contains("auditing the trust boundaries")
                        || lower.contains("running a series of \"execution paths\"")
                        || lower.contains("running a series of execution paths")
                        || lower.contains("dispatching the following specific tasks")
                        || lower.contains("awaiting the first wave of granular results")
                        || lower.contains("observing the concurrent output")
                        || lower.contains("i am now performing a direct")
                        || lower.contains("monitoring status")
                        || lower.contains("i am currently awaiting")
                    ))
                    || lower.contains("i'm retrieving")
                    || lower.contains("i am retrieving")
                    || lower.contains("i will retrieve")
                    || lower.contains("let me retrieve")
                    || lower.contains("i'll retrieve")
                )

                if announcesFutureDelegation && loop < maxLoops - 1 {
                    accumulated = ""
                    messages.append(["role": "assistant", "content": loopText])
                    messages.append([
                        "role": "user",
                        "content": "Invoke the required tool call immediately using the function calling interface or output ONLY a JSON object {\"name\": \"<tool_name>\", \"arguments\": {...}}. Do not narrate in-progress status in text."
                    ])
                    continue
                }

                if accumulated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if !lastToolOutput.isEmpty {
                        accumulated = lastToolOutput
                        onUpdate(accumulated)
                    } else if !thinkingText.isEmpty {
                        onUpdate(thinkingText)
                    } else if loop == 0 {
                        onUpdate("⚠️ Ollama (\(model)) returned no text. Check the model is pulled and Ollama is running.")
                    }
                }
                if ProcessInfo.processInfo.arguments.contains("--cli") {
                    print("\n")
                    fflush(stdout)
                }
                return
            }

            // Append the assistant message (with its tool_calls) so the model
            // sees its own decision on the next turn.
            var assistantEntry: [String: Any] = ["role": "assistant", "content": loopText]
            assistantEntry["tool_calls"] = toolCalls
            messages.append(assistantEntry)

            // Execute each tool through the existing safety pipeline and feed
            // the result back as a tool message.
            var seenCallKeysInBatch: Set<String> = []
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let callId = (call["id"] as? String) ?? UUID().uuidString
                let rawArgs = function["arguments"] as? [String: Any] ?? [:]
                let argsString = (try? JSONSerialization.data(withJSONObject: rawArgs, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                let batchKey = "\(name):\(argsString)"
                if seenCallKeysInBatch.contains(batchKey) {
                    continue
                }
                seenCallKeysInBatch.insert(batchKey)

                if let allowed = allowedTools, !allowed.contains(name) {
                    let msg = "ERROR: Tool '\(name)' is not permitted for this agent."
                    messages.append(["role": "tool", "content": msg, "name": name, "tool_name": name, "tool_call_id": callId])
                    continue
                }

                // If no assistant text has been streamed yet, inform the user/UI of the tool execution
                let toolLabel = name.replacingOccurrences(of: "_", with: " ")
                if accumulated.isEmpty {
                    onUpdate("🔧 *Executing \(toolLabel)...*")
                }

                print("\n⚙️ [Ollama Tool Call] \(name)(\(argsString.prefix(160)))")
                fflush(stdout)
                let output: String
                do {
                    // Route through executeToolByName so logToolStart/logToolEnd fire,
                    // populating the Activity panel and Plan dashboard — matching the
                    // behavior users see with AFM/Gemini turns.
                    output = try await orchestrator.executeToolByName(name: name, jsonArguments: argsString, bot: bot)
                } catch {
                    output = "ERROR: Tool '\(name)' failed: \(error.localizedDescription)"
                }
                lastToolOutput = output
                print("📋 [Ollama Tool Result] \(name) -> \(output.prefix(160))\n")
                fflush(stdout)
                if output.hasPrefix("Loop detected:") {
                    disableToolsOnNextTurn = true
                }
                messages.append(["role": "tool", "content": output, "name": name, "tool_name": name, "tool_call_id": callId])
            }
            // Continue the loop so the model can act on tool results.
        }
    }

    /// Parses raw JSON tool-call objects emitted inside `message.content` by models
    /// (such as `qwen2.5-coder:7b`) that occasionally output `{"name": "...", "arguments": {...}}`
    /// as text rather than populating Ollama's `message.tool_calls` array.
    static func extractFallbackToolCalls(from content: String, availableToolNames: Set<String>) -> [[String: Any]] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = [trimmed]
        if let startBrace = trimmed.firstIndex(of: "{"),
           let endBrace = trimmed.lastIndex(of: "}"),
           startBrace < endBrace {
            candidates.append(String(trimmed[startBrace...endBrace]))
        }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            let rawName = (obj["name"] as? String)
                ?? (obj["tool"] as? String)
                ?? ((obj["function"] as? [String: Any])?["name"] as? String)
            guard let rawName else { continue }

            let resolvedName: String
            if availableToolNames.contains(rawName) {
                resolvedName = rawName
            } else if rawName == "system_info" && availableToolNames.contains("get_system_info") {
                resolvedName = "get_system_info"
            } else {
                continue
            }

            let rawArgs: [String: Any]
            if let argsDict = (obj["arguments"] as? [String: Any])
                ?? (obj["parameters"] as? [String: Any])
                ?? ((obj["function"] as? [String: Any])?["arguments"] as? [String: Any]) {
                rawArgs = argsDict
            } else if let argsStr = (obj["arguments"] as? String) ?? (obj["parameters"] as? String),
                      let argsData = argsStr.data(using: .utf8),
                      let parsedArgs = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                rawArgs = parsedArgs
            } else {
                rawArgs = [:]
            }

            return [[
                "id": UUID().uuidString,
                "function": [
                    "name": resolvedName,
                    "arguments": rawArgs
                ]
            ]]
        }
        return []
    }

    /// Builds an Ollama `/api/chat` user message dictionary, encoding any
    /// attached `NSImage` instances as base64 PNG strings in the `"images"` array
    /// for multimodal vision models (such as `gemma4:12b`).
    static func buildUserMessage(prompt: String, attachments: [NSImage]) -> [String: Any] {
        var userMessage: [String: Any] = ["role": "user", "content": prompt]
        let encodedImages = attachments.compactMap { base64String(from: $0) }
        if !encodedImages.isEmpty {
            userMessage["images"] = encodedImages
        }
        return userMessage
    }
}
