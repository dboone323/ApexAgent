import Foundation
import FoundationModels
import AppKit

public struct CloudGeminiLanguageModel: LanguageModel {
    public typealias Executor = CloudGeminiLanguageModelExecutor
    public let apiKey: String
    
    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }
    
    public var executorConfiguration: CloudGeminiLanguageModelExecutor.Configuration {
        CloudGeminiLanguageModelExecutor.Configuration(apiKey: apiKey)
    }
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

public struct CloudGeminiLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting {
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
        let effectiveKey = configuration.apiKey.isEmpty ? ModelRegistry.geminiAPIKey() : configuration.apiKey
        guard !effectiveKey.isEmpty else {
            throw NSError(domain: "CloudGeminiLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Gemini API Key is missing. Please enter your Gemini API Key in Settings or set GEMINI_API_KEY."])
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
                    case .structure:
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
                    let args = call.arguments.toJSONObject()
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
        
        var currentContents: [[String: Any]] = []
        for content in geminiContents {
            guard let role = content["role"] as? String,
                  let parts = content["parts"] as? [[String: Any]],
                  !parts.isEmpty else {
                continue
            }
            if let lastIdx = currentContents.indices.last,
               let lastRole = currentContents[lastIdx]["role"] as? String,
               lastRole == role,
               var lastParts = currentContents[lastIdx]["parts"] as? [[String: Any]] {
                lastParts.append(contentsOf: parts)
                currentContents[lastIdx]["parts"] = lastParts
            } else {
                currentContents.append(["role": role, "parts": parts])
            }
        }

        if let first = currentContents.first, let role = first["role"] as? String, role != "user" {
            currentContents.insert(["role": "user", "parts": [["text": "Continue task."]]], at: 0)
        }
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
                    
                    let mode: String
                    let tcMode = request.generationOptions.toolCallingMode
                    if tcMode == .allowed {
                        mode = "AUTO"
                    } else if tcMode == .required {
                        mode = "ANY"
                    } else if tcMode == .disallowed {
                        mode = "OFF"
                    } else {
                        mode = "AUTO"
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
            
            let modelName = UserDefaults.standard.string(forKey: "apex.geminiModel") ?? "gemini-3.5-flash"
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):streamGenerateContent?alt=sse"
            guard let url = URL(string: urlStr) else {
                throw NSError(domain: "CloudGeminiLanguageModel", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid Gemini URL configuration."])
            }
            
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(effectiveKey, forHTTPHeaderField: "x-goog-api-key")
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
            let entryID = UUID().uuidString
            
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
                                await channel.send(LanguageModelExecutorGenerationChannel.Event.response(entryID: entryID, action: .appendText(text, segmentID: nil, tokenCount: 0)))
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
                let enabledNames = Set(request.enabledToolDefinitions.map { $0.name })
                let routed = await classifyAndRouteToolCalls(detectedToolCalls, enabledToolNames: enabledNames, channel: channel, entryID: entryID)
                
                if !routed.staticCalls.isEmpty {
                    return
                } else {
                    let dynamicToolCalls = routed.dynamicCalls
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
                    
                    var functionResponses: [[String: Any]] = []
                    for tc in dynamicToolCalls {
                        let output = await executeDynamicTool(name: tc.name, argumentsString: tc.argumentsString)
                        
                        var respObj: [String: Any] = ["content": output]
                        if let data = output.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            respObj = dict
                        }
                        
                        functionResponses.append([
                            "functionResponse": [
                                "name": tc.name,
                                "response": respObj
                            ]
                        ])
                    }
                    
                    if !functionResponses.isEmpty {
                        currentContents.append([
                            "role": "function",
                            "parts": functionResponses
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
