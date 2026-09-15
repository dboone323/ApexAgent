import Foundation
import AppKit

// MARK: - MLX Agent Engine (direct HTTP, bypasses FoundationModels channel)
//
// Dev/testing backend per WWDC26 "Run local agentic AI on the Mac using MLX".
// Talks to an MLX-LM server (mlx_lm.server --model mlx-community/... --port
// 8080) over its OpenAI-compatible /v1/chat/completions SSE endpoint and runs
// tools through the existing allTools/executeWithLogging pipeline
// (confirmation gate + injection sanitizer + audit log). Direct HTTP for the
// same reason as OllamaAgentEngine: the FoundationModels executor channel
// pump SIGSEGVs on macOS 27.0 26A5388g.

@MainActor
struct MLXAgentEngine: AgentEngine {
    let orchestrator: AgentOrchestrator
    var bot: BotProfile?

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let hostString = UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString
        guard let baseURL = URL(string: hostString) else {
            throw NSError(domain: "MLXAgentEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid MLX server URL: \(hostString)"])
        }
        let model = (UserDefaults.standard.string(forKey: "apex.mlxModel") ?? "default_model").trimmingCharacters(in: .whitespacesAndNewlines)
        let useTools = toolCallingMode != .disabled

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

        var tools: [[String: Any]] = []
        if useTools {
            for schema in getParsedSchemas() {
                guard let name = schema["name"] as? String else { continue }
                if let allowedTools = bot?.allowedToolNames,
                   !allowedTools.isEmpty,
                   !allowedTools.contains(name) {
                    continue
                }
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
                throw NSError(domain: "MLXAgentEngine", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize MLX request."])
            }
            var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = httpBody
            request.timeoutInterval = 120

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch {
                throw NSError(domain: "MLXAgentEngine", code: -3, userInfo: [NSLocalizedDescriptionKey: "Cannot reach the MLX-LM server at \(baseURL.absoluteString). Start it with: mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080. (\(error.localizedDescription))"])
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "MLXAgentEngine", code: -4, userInfo: [NSLocalizedDescriptionKey: "MLX-LM server returned HTTP \(code)."])
            }

            var loopText = ""
            // OpenAI SSE streams tool calls as indexed fragments — accumulate.
            var fragments: [Int: (id: String, name: String, arguments: String)] = [:]

            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data: ") else { continue }
                let payload = String(trimmed.dropFirst(6))
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }

                if let content = delta["content"] as? String, !content.isEmpty {
                    loopText += content
                    accumulated += content
                    onUpdate(accumulated)
                }
                if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for toolCall in toolCalls {
                        let index = toolCall["index"] as? Int ?? 0
                        var fragment = fragments[index] ?? (id: "", name: "", arguments: "")
                        if let id = toolCall["id"] as? String, !id.isEmpty { fragment.id = id }
                        if let function = toolCall["function"] as? [String: Any] {
                            if let name = function["name"] as? String, !name.isEmpty { fragment.name += name }
                            if let args = function["arguments"] as? String { fragment.arguments += args }
                        }
                        fragments[index] = fragment
                    }
                }
            }

            let toolCallFragments = fragments.sorted(by: { $0.key < $1.key }).map(\.value).filter { !$0.name.isEmpty }

            if toolCallFragments.isEmpty {
                if loop == 0 && loopText.isEmpty {
                    onUpdate("⚠️ The MLX-LM server (\(model)) returned no text. Check that the server is running and a model is loaded.")
                }
                return
            }

            var toolCallsArray: [[String: Any]] = []
            for fragment in toolCallFragments {
                let callId = fragment.id.isEmpty ? UUID().uuidString : fragment.id
                toolCallsArray.append([
                    "id": callId,
                    "type": "function",
                    "function": ["name": fragment.name, "arguments": fragment.arguments.isEmpty ? "{}" : fragment.arguments]
                ])
            }
            messages.append(["role": "assistant", "content": loopText, "tool_calls": toolCallsArray])

            for (offset, fragment) in toolCallFragments.enumerated() {
                let callId = (toolCallsArray[offset]["id"] as? String) ?? UUID().uuidString
                let name = fragment.name
                let argsString = fragment.arguments.isEmpty ? "{}" : fragment.arguments

                let output: String
                do {
                    output = try await orchestrator.executeToolByName(
                        name: name,
                        jsonArguments: argsString,
                        bot: bot,
                        agentIdentity: bot.map { .bot(id: $0.id, name: $0.name) }
                    )
                } catch {
                    output = "ERROR: Tool '\(name)' failed: \(error.localizedDescription)"
                }
                messages.append(["role": "tool", "content": output, "tool_call_id": callId])
            }
            // Continue the loop so the model can act on tool results.
        }
    }
}
