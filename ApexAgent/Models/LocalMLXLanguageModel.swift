import Foundation
import FoundationModels

// MARK: - Local MLX Language Model (MLX-LM server, OpenAI-compatible API)
//
// Brings an MLX-LM server (mlx_lm.server --model mlx-community/... --port 8080)
// into the Foundation Models framework via LanguageModel/LanguageModelExecutor —
// the supported provider path per WWDC26 session 339 ("Bring an LLM provider to
// the Foundation Models framework"). MLX-LM exposes an OpenAI-compatible
// /v1/chat/completions endpoint (SSE streaming), unlike Ollama's native
// /api/chat NDJSON, so this executor speaks the OpenAI wire format.
//
// NOTE (macOS 27.0 26A5388g): the FoundationModels executor channel pump
// SIGSEGVs on this build (same beta skew as LocalOllamaLanguageModel). This
// conformance is correct and kept for fixed OS builds; the working runtime
// path on 26A5388g is MLXAgentEngine (direct HTTP, no FM channel).

public struct LocalMLXLanguageModel: LanguageModel {
    public typealias Executor = LocalMLXLanguageModelExecutor
    public let hostURL: URL

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    public var executorConfiguration: LocalMLXLanguageModelExecutor.Configuration {
        LocalMLXLanguageModelExecutor.Configuration(hostURL: hostURL)
    }

    public init(hostURL: URL) {
        self.hostURL = hostURL
    }

    public static let defaultHostURLString = "http://127.0.0.1:8080"

    /// Quick availability probe — is an MLX-LM server answering on the host?
    public static func isAvailable(hostURL: URL) async -> Bool {
        let url = hostURL.appendingPathComponent("v1/models")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

public struct LocalMLXLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting {
    public typealias Model = LocalMLXLanguageModel

    public struct Configuration: Hashable, Sendable {
        public let hostURL: URL
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: LocalMLXLanguageModel, transcript: Transcript) {}

    private func getOpenAITools(for names: [String]) async -> [[String: Any]] {
        let data = await getParsedSchemasJSONData()
        guard let schemas = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return schemas
            .filter { schema in
                guard let name = schema["name"] as? String else { return false }
                return names.contains(name)
            }
            .map { ["type": "function", "function": $0] }
    }

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: LocalMLXLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let savedModel = UserDefaults.standard.string(forKey: "apex.mlxModel") ?? "default_model"

        // Map the FoundationModels transcript → OpenAI chat messages.
        var messages: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                var text = ""
                for segment in inst.segments {
                    if case .text(let seg) = segment { text += seg.content }
                }
                messages.append(["role": "system", "content": text])
            case .prompt(let prompt):
                var text = ""
                for segment in prompt.segments {
                    if case .text(let seg) = segment { text += seg.content }
                }
                messages.append(["role": "user", "content": text])
            case .response(let response):
                var text = ""
                for segment in response.segments {
                    if case .text(let seg) = segment { text += seg.content }
                }
                messages.append(["role": "assistant", "content": text])
            case .toolCalls(let toolCalls):
                var callsArray: [[String: Any]] = []
                for call in toolCalls {
                    // OpenAI format: arguments is a JSON *string*.
                    let argsObject = call.arguments.toJSONObject()
                    let argsString = (try? JSONSerialization.data(withJSONObject: argsObject))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    callsArray.append([
                        "id": call.id,
                        "type": "function",
                        "function": ["name": call.toolName, "arguments": argsString]
                    ])
                }
                messages.append(["role": "assistant", "content": "", "tool_calls": callsArray])
            case .toolOutput(let toolOutput):
                var text = ""
                for segment in toolOutput.segments {
                    if case .text(let seg) = segment { text += seg.content }
                }
                messages.append(["role": "tool", "content": text, "tool_call_id": toolOutput.id])
            case .reasoning(let reasoning):
                var text = ""
                for segment in reasoning.segments {
                    if case .text(let seg) = segment { text += seg.content }
                }
                if !text.isEmpty {
                    messages.append(["role": "assistant", "content": text])
                }
            case .data:
                break
            @unknown default:
                break
            }
        }

        var currentMessages = messages
        let entryID = UUID().uuidString
        var loopCount = 0
        let maxLoops = 8

        while loopCount < maxLoops {
            var requestBody: [String: Any] = [
                "model": savedModel,
                "messages": currentMessages,
                "stream": true
            ]
            if request.generationOptions.toolCallingMode != .disallowed {
                let names = request.enabledToolDefinitions.map { $0.name }
                let tools = await getOpenAITools(for: names)
                if !tools.isEmpty { requestBody["tools"] = tools }
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
                throw NSError(domain: "LocalMLXLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize MLX request payload."])
            }

            var urlRequest = URLRequest(url: configuration.hostURL.appendingPathComponent("v1/chat/completions"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = jsonData
            urlRequest.timeoutInterval = 120

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            } catch {
                throw NSError(domain: "LocalMLXLanguageModel", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to the MLX-LM server at \(configuration.hostURL.absoluteString). Start it with: mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080. Error: \(error.localizedDescription)"])
            }
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "LocalMLXLanguageModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "MLX-LM server returned status code \(code)"])
            }

            var detectedToolCalls: [ParsedToolCall] = []
            // OpenAI streams tool calls as indexed fragments — accumulate them.
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
                    await channel.send(LanguageModelExecutorGenerationChannel.Event.response(entryID: entryID, action: .appendText(content, segmentID: nil, tokenCount: 0)))
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

            for (_, fragment) in fragments.sorted(by: { $0.key < $1.key }) {
                guard !fragment.name.isEmpty else { continue }
                let callId = fragment.id.isEmpty ? UUID().uuidString : fragment.id
                let argsString = fragment.arguments.isEmpty ? "{}" : fragment.arguments
                let argsObject = (argsString.data(using: .utf8))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                detectedToolCalls.append(ParsedToolCall(id: callId, name: fragment.name, arguments: argsObject, argumentsString: argsString))
            }

            if !detectedToolCalls.isEmpty {
                let enabledNames = Set(request.enabledToolDefinitions.map { $0.name })
                let routed = await classifyAndRouteToolCalls(detectedToolCalls, enabledToolNames: enabledNames, channel: channel, entryID: entryID)

                if !routed.staticCalls.isEmpty {
                    return
                } else {
                    var toolCallsArray: [[String: Any]] = []
                    for tc in routed.dynamicCalls {
                        toolCallsArray.append([
                            "id": tc.id,
                            "type": "function",
                            "function": ["name": tc.name, "arguments": tc.argumentsString]
                        ])
                    }
                    currentMessages.append(["role": "assistant", "content": "", "tool_calls": toolCallsArray])
                    for tc in routed.dynamicCalls {
                        let output = await executeDynamicTool(name: tc.name, argumentsString: tc.argumentsString)
                        currentMessages.append(["role": "tool", "content": output, "tool_call_id": tc.id])
                    }
                }
            } else {
                return
            }
            loopCount += 1
        }
    }
}
