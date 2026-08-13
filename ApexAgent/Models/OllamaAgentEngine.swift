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

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let hostString = UserDefaults.standard.string(forKey: "apex.ollamaHost") ?? "http://localhost:11434"
        guard let baseURL = URL(string: hostString) else {
            throw NSError(domain: "OllamaAgentEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama host URL: \(hostString)"])
        }
        // Default to gemma4:12b when unset: a strong local model for Apple
        // Silicon on macOS 27 (Gemma 4 family, ~7.6GB). Falls back to a clear
        // "model not pulled" error from Ollama if it isn't available.
        let model = (UserDefaults.standard.string(forKey: "apex.ollamaModel") ?? "gemma4:12b").trimmingCharacters(in: .whitespacesAndNewlines)
        let useTools = toolCallingMode != .disabled

        // Map history + system instructions + new prompt into Ollama messages.
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        for msg in history {
            let role: String = switch msg.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            }
            messages.append(["role": role, "content": msg.content])
        }
        messages.append(["role": "user", "content": prompt])

        // Build Ollama function-tool schemas from the live tool registry.
        var tools: [[String: Any]] = []
        if useTools {
            for schema in getParsedSchemas() {
                guard schema["name"] is String else { continue }
                tools.append(["type": "function", "function": schema])
            }
        }

        var accumulated = ""
        let maxLoops = 8
        for loop in 0..<maxLoops {
            var body: [String: Any] = [
                "model": model,
                "messages": messages,
                "stream": true
            ]
            if !tools.isEmpty { body["tools"] = tools }

            guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
                throw NSError(domain: "OllamaAgentEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Ollama request."])
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody
            request.timeoutInterval = 120

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
            var toolCalls: [[String: Any]] = []
            for try await line in bytes.lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                guard let message = json["message"] as? [String: Any] else { continue }
                if let content = message["content"] as? String, !content.isEmpty {
                    loopText += content
                    accumulated += content
                    onUpdate(accumulated)
                }
                if let calls = message["tool_calls"] as? [[String: Any]] {
                    toolCalls.append(contentsOf: calls)
                }
            }

            // No tool calls -> final answer, we're done.
            if toolCalls.isEmpty {
                if loop == 0 && loopText.isEmpty {
                    onUpdate("⚠️ Ollama (\(model)) returned no text. Check the model is pulled and Ollama is running.")
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
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let callId = (call["id"] as? String) ?? UUID().uuidString
                let rawArgs = function["arguments"] as? [String: Any] ?? [:]
                let argsString = (try? JSONSerialization.data(withJSONObject: rawArgs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                guard let tool = orchestrator.allTools.first(where: { $0.name == name }) else {
                    let msg = "ERROR: Tool '\(name)' is not registered."
                    messages.append(["role": "tool", "content": msg, "name": name, "tool_call_id": callId])
                    continue
                }
                let output: String
                do {
                    output = try await tool.execute(jsonArguments: argsString)
                } catch {
                    output = "ERROR: Tool '\(name)' failed: \(error.localizedDescription)"
                }
                messages.append(["role": "tool", "content": output, "name": name, "tool_call_id": callId])
            }
            // Continue the loop so the model can act on tool results.
        }
    }
}
