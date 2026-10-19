import Foundation
import FoundationModels

public struct LocalOllamaLanguageModel: LanguageModel {
    public typealias Executor = LocalOllamaLanguageModelExecutor
    public let hostURL: URL
    
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }
    
    public var executorConfiguration: LocalOllamaLanguageModelExecutor.Configuration {
        LocalOllamaLanguageModelExecutor.Configuration(hostURL: hostURL)
    }
    
    public init(hostURL: URL) {
        self.hostURL = hostURL
    }

    // MARK: - Markdown Telemetry

    public func formatOllamaStatusMarkdown() -> String {
        var md = "### 🦙 Local Ollama Language Model Telemetry\n\n"
        md += "| Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Host Endpoint | `\(hostURL.absoluteString)` | Local Ollama daemon URL |\n"
        md += "| Capabilities | Tool Calling, Reasoning | Native FoundationModels extensions |\n"
        md += "| Hardware Target | Apple Silicon Unified Memory | Metal acceleration |\n"
        return md
    }
}

public struct ParsedToolCall {
    public let id: String
    public let name: String
    public let arguments: [String: Any]
    public let argumentsString: String
    
    public init(id: String, name: String, arguments: [String: Any], argumentsString: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.argumentsString = argumentsString
    }
}

public struct LocalOllamaLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting {
    public typealias Model = LocalOllamaLanguageModel
    
    public struct Configuration: Hashable, Sendable {
        public let hostURL: URL
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }
    
    public func prewarm(model: LocalOllamaLanguageModel, transcript: Transcript) {}
    
    private func getOllamaTools(for names: [String]) async -> [[String: Any]] {
        let data = await getParsedSchemasJSONData()
        guard let schemas = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let filtered = schemas.filter { schema in
            guard let name = schema["name"] as? String else { return false }
            return names.contains(name)
        }
        return filtered.map { schema in
            [
                "type": "function",
                "function": schema
            ]
        }
    }
    
    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: LocalOllamaLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let savedModel = UserDefaults.standard.string(forKey: "apex.ollamaModel") ?? "gemma4:12b"
        
        var ollamaMessages: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                var systemText = ""
                for segment in inst.segments {
                    if case .text(let textSeg) = segment {
                        systemText += textSeg.content
                    }
                }
                ollamaMessages.append(["role": "system", "content": systemText])
            case .prompt(let prompt):
                var userText = ""
                for segment in prompt.segments {
                    if case .text(let textSeg) = segment {
                        userText += textSeg.content
                    }
                }
                ollamaMessages.append(["role": "user", "content": userText])
            case .response(let response):
                var assistantText = ""
                for segment in response.segments {
                    if case .text(let textSeg) = segment {
                        assistantText += textSeg.content
                    }
                }
                ollamaMessages.append(["role": "assistant", "content": assistantText])
            case .toolCalls(let toolCalls):
                var callsArray: [[String: Any]] = []
                for call in toolCalls {
                    let args = call.arguments.toJSONObject()
                    callsArray.append([
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.toolName,
                            "arguments": args
                        ]
                    ])
                }
                ollamaMessages.append([
                    "role": "assistant",
                    "content": "",
                    "tool_calls": callsArray
                ])
            case .toolOutput(let toolOutput):
                var contentText = ""
                for segment in toolOutput.segments {
                    if case .text(let textSeg) = segment {
                        contentText += textSeg.content
                    }
                }
                ollamaMessages.append([
                    "role": "tool",
                    "content": contentText,
                    "name": toolOutput.toolName,
                    "tool_call_id": toolOutput.id
                ])
            case .reasoning(let reasoning):
                var reasoningText = ""
                for segment in reasoning.segments {
                    if case .text(let textSeg) = segment {
                        reasoningText += textSeg.content
                    }
                }
                if !reasoningText.isEmpty {
                    ollamaMessages.append(["role": "assistant", "content": reasoningText])
                }
            case .data:
                break
            @unknown default:
                break
            }
        }
        
        var currentMessages = ollamaMessages
        let entryID = UUID().uuidString
        var loopCount = 0
        let maxLoops = 8
        
        _ = await ModelRegistry.unloadPreviousOllamaModelIfNeededAsync(newModel: savedModel)
        
        while loopCount < maxLoops {
            var requestBody: [String: Any] = [
                "model": savedModel,
                "messages": currentMessages,
                "stream": true,
                "keep_alive": "2m",
                "options": [
                    "num_ctx": 8192
                ]
            ]
            
            if request.generationOptions.toolCallingMode != .disallowed {
                let names = request.enabledToolDefinitions.map { $0.name }
                let tools = await getOllamaTools(for: names)
                if !tools.isEmpty {
                    requestBody["tools"] = tools
                }
            }
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
                throw NSError(domain: "LocalOllamaLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Ollama request payload."])
            }
            
            var urlRequest = URLRequest(url: configuration.hostURL.appendingPathComponent("api/chat"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = jsonData
            urlRequest.timeoutInterval = 60
            
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            } catch {
                throw NSError(domain: "LocalOllamaLanguageModel", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Ollama. Make sure Ollama is running at \(configuration.hostURL.absoluteString) and the model '\(savedModel)' has been pulled. Error: \(error.localizedDescription)"])
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "LocalOllamaLanguageModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Ollama returned status code \(code)"])
            }
            
            var accumulatedText = ""
            var detectedToolCalls: [ParsedToolCall] = []
            
            for try await line in bytes.lines {
                try Task.checkCancellation()
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                
                if let message = json["message"] as? [String: Any] {
                    if let content = message["content"] as? String, !content.isEmpty {
                        accumulatedText += content
                        await channel.send(LanguageModelExecutorGenerationChannel.Event.response(entryID: entryID, action: .appendText(content, segmentID: nil, tokenCount: 0)))
                    }
                    if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                        for toolCall in toolCalls {
                            guard let function = toolCall["function"] as? [String: Any],
                                  let name = function["name"] as? String,
                                  let args = function["arguments"] as? [String: Any] else {
                                continue
                            }
                            let callId = toolCall["id"] as? String ?? UUID().uuidString
                            guard let argsData = try? JSONSerialization.data(withJSONObject: args),
                                  let argsStr = String(data: argsData, encoding: .utf8) else {
                                continue
                            }
                            detectedToolCalls.append(ParsedToolCall(id: callId, name: name, arguments: args, argumentsString: argsStr))
                        }
                    }
                }
            }
            
            if !detectedToolCalls.isEmpty {
                let enabledNames = Set(request.enabledToolDefinitions.map { $0.name })
                let routed = await classifyAndRouteToolCalls(detectedToolCalls, enabledToolNames: enabledNames, channel: channel, entryID: entryID)
                
                if !routed.staticCalls.isEmpty {
                    return
                } else {
                    let dynamicToolCalls = routed.dynamicCalls
                    var toolCallsArray: [[String: Any]] = []
                    for tc in dynamicToolCalls {
                        toolCallsArray.append([
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments
                            ]
                        ])
                    }
                    
                    currentMessages.append([
                        "role": "assistant",
                        "content": accumulatedText,
                        "tool_calls": toolCallsArray
                    ])
                    
                    for tc in dynamicToolCalls {
                        let output = await executeDynamicTool(name: tc.name, argumentsString: tc.argumentsString)
                        currentMessages.append([
                            "role": "tool",
                            "content": output,
                            "name": tc.name,
                            "tool_call_id": tc.id
                        ])
                    }
                }
            } else {
                return
            }
            loopCount += 1
        }
    }
}
