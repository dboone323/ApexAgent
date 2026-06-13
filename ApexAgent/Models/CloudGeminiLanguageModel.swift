import Foundation
import FoundationModels
import AppKit

public struct CloudGeminiLanguageModel: LanguageModel {
    public typealias Executor = CloudGeminiLanguageModelExecutor
    public let apiKey: String
    
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities(capabilities: [.toolCalling, .reasoning])
    }
    
    public var executorConfiguration: CloudGeminiLanguageModelExecutor.Configuration {
        CloudGeminiLanguageModelExecutor.Configuration(apiKey: apiKey)
    }
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

public struct CloudGeminiLanguageModelExecutor: LanguageModelExecutor {
    public typealias Model = CloudGeminiLanguageModel
    
    public struct Configuration: Hashable, Sendable {
        public let apiKey: String
    }
    
    public let configuration: Configuration
    
    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }
    
    public func prewarm(model: CloudGeminiLanguageModel, transcript: Transcript) {}
    
    private func getGeminiTools(for names: [String]) async -> [[String: Any]] {
        let data = await getParsedGeminiFunctionDeclarationsJSONData()
        guard let decls = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let filteredDecls = decls.filter { decl in
            guard let name = decl["name"] as? String else { return false }
            return names.contains(name)
        }
        guard !filteredDecls.isEmpty else { return [] }
        return [["functionDeclarations": filteredDecls]]
    }
    
    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: CloudGeminiLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        guard !configuration.apiKey.isEmpty else {
            throw NSError(domain: "CloudGeminiLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is missing."])
        }
        
        var geminiContents: [[String: Any]] = []
        var systemInstructions = ""
        
        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                for segment in inst.segments {
                    if case .text(let textSeg) = segment {
                        systemInstructions += textSeg.content
                    }
                }
            case .prompt(let prompt):
                var parts: [[String: Any]] = []
                for segment in prompt.segments {
                    switch segment {
                    case .text(let textSeg):
                        parts.append(["text": textSeg.content])
                    case .attachment(let attachSeg):
                        if case .image(let imageAttach) = attachSeg.content {
                            let cgImage = imageAttach.cgImage
                            let nsImage = NSImage(cgImage: cgImage, size: .zero)
                            if let b64 = base64String(from: nsImage) {
                                parts.append([
                                    "inlineData": [
                                        "mimeType": "image/png",
                                        "data": b64
                                    ]
                                ])
                            }
                        }
                    case .structure(_):
                        break
                    case .custom(_):
                        break
                    @unknown default:
                        break
                    }
                }
                geminiContents.append([
                    "role": "user",
                    "parts": parts
                ])
            case .response(let response):
                var parts: [[String: Any]] = []
                for segment in response.segments {
                    if case .text(let textSeg) = segment {
                        parts.append(["text": textSeg.content])
                    }
                }
                geminiContents.append([
                    "role": "model",
                    "parts": parts
                ])
            case .toolCalls(let toolCalls):
                var parts: [[String: Any]] = []
                for call in toolCalls {
                    let args = jsonObject(from: call.arguments)
                    parts.append([
                        "functionCall": [
                            "name": call.toolName,
                            "args": args
                        ]
                    ])
                }
                geminiContents.append([
                    "role": "model",
                    "parts": parts
                ])
            case .toolOutput(let toolOutput):
                var contentText = ""
                for segment in toolOutput.segments {
                    if case .text(let textSeg) = segment {
                        contentText += textSeg.content
                    }
                }
                
                var respObj: [String: Any] = ["content": contentText]
                if let data = contentText.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    respObj = dict
                }
                
                geminiContents.append([
                    "role": "function",
                    "parts": [[
                        "functionResponse": [
                            "name": toolOutput.toolName,
                            "response": respObj
                        ]
                    ]]
                ])
            case .reasoning(let reasoning):
                var parts: [[String: Any]] = []
                for segment in reasoning.segments {
                    if case .text(let textSeg) = segment {
                        parts.append(["text": textSeg.content])
                    }
                }
                if !parts.isEmpty {
                    geminiContents.append([
                        "role": "model",
                        "parts": parts
                    ])
                }
            @unknown default:
                break
            }
        }
        
        var currentContents = geminiContents
        var loopCount = 0
        let maxLoops = 8
        
        while loopCount < maxLoops {
            var requestBody: [String: Any] = [
                "contents": currentContents
            ]
            if !systemInstructions.isEmpty {
                requestBody["systemInstruction"] = [
                    "parts": [["text": systemInstructions]]
                ]
            }
            
            if request.generationOptions.toolCallingMode != .disallowed {
                let names = request.enabledToolDefinitions.map { $0.name }
                let tools = await getGeminiTools(for: names)
                if !tools.isEmpty {
                    requestBody["tools"] = tools
                    
                    let mode: String = switch request.generationOptions.toolCallingMode {
                    case .allowed?: "AUTO"
                    case .required?: "ANY"
                    case .disallowed?, .none: "OFF"
                    @unknown default: "AUTO"
                    }
                    
                    requestBody["toolConfig"] = [
                        "functionCallingConfig": [
                            "mode": mode
                        ]
                    ]
                }
            }
            
            guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
                throw NSError(domain: "CloudGeminiLanguageModel", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize Gemini request payload."])
            }
            
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:streamGenerateContent?alt=sse&key=\(configuration.apiKey)"
            guard let url = URL(string: urlStr) else {
                throw NSError(domain: "CloudGeminiLanguageModel", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL configuration."])
            }
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = jsonData
            urlRequest.timeoutInterval = 60
            
            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
            } catch {
                throw NSError(domain: "CloudGeminiLanguageModel", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to connect to Google Gemini API: \(error.localizedDescription)"])
            }
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "CloudGeminiLanguageModel", code: -4, userInfo: [NSLocalizedDescriptionKey: "Gemini API returned status code \(code)"])
            }
            
            var accumulatedText = ""
            var detectedToolCalls: [ParsedToolCall] = []
            
            for try await line in bytes.lines {
                if line.hasPrefix("data: ") {
                    let jsonStr = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
                    if jsonStr == "[DONE]" { break }
                    
                    guard let data = jsonStr.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    
                    if let candidates = json["candidates"] as? [[String: Any]],
                       let candidate = candidates.first,
                       let content = candidate["content"] as? [String: Any],
                       let parts = content["parts"] as? [[String: Any]] {
                        
                        for part in parts {
                            if let text = part["text"] as? String {
                                accumulatedText += text
                                await channel.send(LanguageModelExecutorGenerationChannel.Response.response(action: .appendText(text, tokenCount: 0)))
                            }
                            if let functionCall = part["functionCall"] as? [String: Any],
                               let name = functionCall["name"] as? String,
                               let args = functionCall["args"] as? [String: Any] {
                                
                                guard let argsData = try? JSONSerialization.data(withJSONObject: args),
                                      let argsStr = String(data: argsData, encoding: .utf8) else {
                                    continue
                                }
                                
                                detectedToolCalls.append(ParsedToolCall(id: UUID().uuidString, name: name, arguments: args, argumentsString: argsStr))
                            }
                        }
                    }
                }
            }
            
            if !detectedToolCalls.isEmpty {
                var dynamicToolCalls: [ParsedToolCall] = []
                var staticToolCalls: [ParsedToolCall] = []
                
                let enabledNames = Set(request.enabledToolDefinitions.map { $0.name })
                
                for tc in detectedToolCalls {
                    let toolName = tc.name
                    let isDynamic = await MainActor.run {
                        return DynamicToolbox.shared.dynamicTools[toolName] != nil
                    }
                    if isDynamic && !enabledNames.contains(tc.name) {
                        dynamicToolCalls.append(tc)
                    } else {
                        staticToolCalls.append(tc)
                    }
                }
                
                if !staticToolCalls.isEmpty {
                    for tc in staticToolCalls {
                        let toolCallAction = LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action.appendArguments(tc.argumentsString, tokenCount: 0)
                        let action = LanguageModelExecutorGenerationChannel.ToolCalls.Action.toolCall(id: tc.id, name: tc.name, action: toolCallAction)
                        let event = LanguageModelExecutorGenerationChannel.ToolCalls.toolCalls(action: action)
                        await channel.send(event)
                    }
                    return
                } else {
                    var parts: [[String: Any]] = []
                    if !accumulatedText.isEmpty {
                        parts.append(["text": accumulatedText])
                    }
                    for tc in dynamicToolCalls {
                        parts.append([
                            "functionCall": [
                                "name": tc.name,
                                "args": tc.arguments
                            ]
                        ])
                    }
                    
                    currentContents.append([
                        "role": "model",
                        "parts": parts
                    ])
                    
                    for tc in dynamicToolCalls {
                        let output: String
                        do {
                            output = try await DynamicToolbox.shared.executeTool(name: tc.name, jsonArguments: tc.argumentsString)
                        } catch {
                            output = "ERROR: \(error.localizedDescription)"
                        }
                        
                        var respObj: [String: Any] = ["content": output]
                        if let data = output.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            respObj = dict
                        }
                        
                        currentContents.append([
                            "role": "function",
                            "parts": [[
                                "functionResponse": [
                                    "name": tc.name,
                                    "response": respObj
                                ]
                            ]]
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

// Helpers
private func jsonObject(from content: GeneratedContent) -> Any {
    switch content.kind {
    case .null:
        return NSNull()
    case .bool(let value):
        return value
    case .number(let value):
        return value
    case .string(let value):
        return value
    case .array(let array):
        return array.map { jsonObject(from: $0) }
    case .structure(let properties, _):
        var dict: [String: Any] = [:]
        for (k, v) in properties {
            dict[k] = jsonObject(from: v)
        }
        return dict
    @unknown default:
        return NSNull()
    }
}
