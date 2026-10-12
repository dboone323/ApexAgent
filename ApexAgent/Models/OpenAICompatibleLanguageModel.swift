import Foundation
import FoundationModels
import AppKit

// MARK: - Universal OpenAI-Compatible Language Model (Batch 101)
//
// Native FoundationModels LanguageModel implementation supporting OpenAI, OpenRouter,
// Groq, DeepSeek, Together AI, Mistral, and local vLLM / LM Studio / LocalAI inference.

public struct OpenAICompatibleConfiguration: Hashable, Sendable, Codable, Equatable {
    public var endpointURL: URL
    public var apiKey: String
    public var modelName: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var customHeaders: [String: String]

    public init(
        endpointURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        apiKey: String = "",
        modelName: String = "gpt-4o",
        temperature: Double? = 0.7,
        maxTokens: Int? = 4096,
        customHeaders: [String: String] = [:]
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.customHeaders = customHeaders
    }
}

public struct OpenAICompatibleLanguageModel: LanguageModel {
    public typealias Executor = OpenAICompatibleLanguageModelExecutor

    public let configuration: OpenAICompatibleConfiguration

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    public var executorConfiguration: OpenAICompatibleLanguageModelExecutor.Configuration {
        OpenAICompatibleLanguageModelExecutor.Configuration(configuration: configuration)
    }

    public init(configuration: OpenAICompatibleConfiguration) {
        self.configuration = configuration
    }

    public init(
        endpointURL: URL = URL(string: "https://api.openai.com/v1/chat/completions")!,
        apiKey: String = "",
        modelName: String = "gpt-4o"
    ) {
        self.configuration = OpenAICompatibleConfiguration(
            endpointURL: endpointURL,
            apiKey: apiKey,
            modelName: modelName
        )
    }

    // MARK: - Markdown Telemetry

    public func formatOpenAIConfigurationMarkdown() -> String {
        var md = "### 🌐 Universal OpenAI-Compatible Model Telemetry\n\n"
        md += "| Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Endpoint | `\(configuration.endpointURL.absoluteString)` | REST chat completions target |\n"
        md += "| Model Name | `\(configuration.modelName)` | Remote model identifier |\n"
        let keyStatus = configuration.apiKey.isEmpty ? "⚪️ Missing (Keychain / Env Fallback)" : "🟢 Configured (Redacted)"
        md += "| API Key Status | \(keyStatus) | Bearer authorization token |\n"
        md += "| Capabilities | Tool Calling, Reasoning | Native FoundationModels extensions |\n"
        return md
    }
}

public struct OpenAICompatibleLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting {
    public typealias Model = OpenAICompatibleLanguageModel

    public struct Configuration: Hashable, Sendable {
        public let configuration: OpenAICompatibleConfiguration
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: OpenAICompatibleLanguageModel, transcript: Transcript) {}

    // MARK: - Tool Extraction

    public func getOpenAITools(for names: [String]) async -> [[String: Any]] {
        let data = await getParsedSchemasJSONData()
        guard let schemas = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        let filtered = schemas.filter { schema in
            guard let name = schema["name"] as? String else { return false }
            return names.contains(name)
        }
        guard !filtered.isEmpty else { return [] }

        return filtered.map { schema in
            let name = schema["name"] as? String ?? ""
            let desc = schema["description"] as? String ?? ""
            let params = schema["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]]
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": desc,
                    "parameters": params
                ]
            ]
        }
    }

    // MARK: - Execution

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenAICompatibleLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let config = configuration.configuration
        let effectiveKey = config.apiKey.isEmpty ? (KeychainManager.get(key: "openAIAPIKey") ?? "") : config.apiKey

        // 1. Build messages array from Transcript
        var messages: [[String: Any]] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                var text = ""
                for segment in inst.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
                }
                if !text.isEmpty {
                    messages.append(["role": "system", "content": text])
                }

            case .prompt(let prompt):
                var text = ""
                for segment in prompt.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
                }
                messages.append(["role": "user", "content": text])

            case .response(let response):
                var text = ""
                for segment in response.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
                }
                messages.append(["role": "assistant", "content": text])

            case .toolCalls(let toolCalls):
                var calls: [[String: Any]] = []
                for (idx, call) in toolCalls.enumerated() {
                    let args = call.arguments.toJSONObject()
                    let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
                    let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
                    calls.append([
                        "id": "call_\(idx)_\(call.toolName)",
                        "type": "function",
                        "function": [
                            "name": call.toolName,
                            "arguments": argsString
                        ]
                    ])
                }
                messages.append([
                    "role": "assistant",
                    "content": NSNull(),
                    "tool_calls": calls
                ])

            case .toolOutput(let toolOutput):
                var text = ""
                for segment in toolOutput.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
                }
                messages.append([
                    "role": "tool",
                    "tool_call_id": "call_0",
                    "content": text
                ])

            case .reasoning(let reasoning):
                var text = ""
                for segment in reasoning.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
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

        // 2. Fetch Tools
        var toolsPayload: [[String: Any]] = []
        if request.generationOptions.toolCallingMode != .disallowed {
            let names = request.enabledToolDefinitions.map(\.name)
            if !names.isEmpty {
                toolsPayload = await getOpenAITools(for: names)
            }
        }

        // 3. Assemble JSON Payload
        var requestDict: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "stream": true
        ]
        if let temp = config.temperature {
            requestDict["temperature"] = temp
        }
        if let maxT = config.maxTokens {
            requestDict["max_tokens"] = maxT
        }
        if !toolsPayload.isEmpty {
            requestDict["tools"] = toolsPayload
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestDict)

        // 4. Create URLRequest
        var urlRequest = URLRequest(url: config.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !effectiveKey.isEmpty {
            urlRequest.setValue("Bearer \(effectiveKey)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in config.customHeaders {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        urlRequest.httpBody = bodyData

        // 5. Stream execution via URLSession
        let session = URLSession(configuration: .default)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OpenAICompatibleLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw NSError(domain: "OpenAICompatibleLanguageModel", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(httpResponse.statusCode)"])
        }

        // 6. SSE Line Accumulator
        let entryID = UUID().uuidString
        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }

            guard let chunkData = payload.data(using: .utf8),
                  let chunkJSON = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any],
                  let choices = chunkJSON["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any] else {
                continue
            }

            if let content = delta["content"] as? String, !content.isEmpty {
                await channel.send(LanguageModelExecutorGenerationChannel.Event.response(entryID: entryID, action: .appendText(content, segmentID: nil, tokenCount: 0)))
            }
        }
    }
}

// MARK: - OpenAI Wire Protocol & Security Auditor

public struct OpenAIWireViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct OpenAIWireAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [OpenAIWireViolation]
    public let sanitizedEndpoint: String?
    public let redactedKey: String?

    public init(
        passed: Bool,
        score: Double,
        violations: [OpenAIWireViolation],
        sanitizedEndpoint: String?,
        redactedKey: String?
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.sanitizedEndpoint = sanitizedEndpoint
        self.redactedKey = redactedKey
    }
}

public enum OpenAIWireProtocolAuditor {

    /// Audits an OpenAI-compatible endpoint URL and API key for transport security and leak prevention.
    public static func auditConfiguration(_ config: OpenAICompatibleConfiguration) -> OpenAIWireAuditReport {
        var violations: [OpenAIWireViolation] = []

        // 1. Endpoint URL verification
        let scheme = config.endpointURL.scheme?.lowercased() ?? ""
        let host = config.endpointURL.host?.lowercased() ?? ""
        let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")

        if scheme != "https" && !isLocal {
            violations.append(OpenAIWireViolation(
                code: "INSECURE_HTTP_ENDPOINT",
                message: "Remote endpoint must use HTTPS to prevent credential interception."
            ))
        }

        if !config.endpointURL.path.contains("chat/completions") {
            violations.append(OpenAIWireViolation(
                code: "NON_STANDARD_ENDPOINT_PATH",
                message: "Path should typically end in '/chat/completions' (found: '\(config.endpointURL.path)').",
                isFatal: false
            ))
        }

        // 2. API Key verification
        let cleanKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanKey.isEmpty && !isLocal {
            violations.append(OpenAIWireViolation(
                code: "MISSING_API_KEY",
                message: "API key is missing for remote endpoint.",
                isFatal: false
            ))
        }

        // 3. Redact key safely (e.g. sk-...abcd)
        var redacted: String? = nil
        if !cleanKey.isEmpty {
            if cleanKey.count > 8 {
                let prefix = String(cleanKey.prefix(3))
                let suffix = String(cleanKey.suffix(4))
                redacted = "\(prefix)...\(suffix)"
            } else {
                redacted = "***"
            }
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 40.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        return OpenAIWireAuditReport(
            passed: passed,
            score: score,
            violations: violations,
            sanitizedEndpoint: config.endpointURL.absoluteString,
            redactedKey: redacted
        )
    }

    /// Parses an SSE text chunk and extracts textual delta content and finish reasons.
    public static func parseSSEChunk(_ sseLine: String) -> (contentDelta: String?, reasoningDelta: String?, isDone: Bool) {
        let trimmed = sseLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return (nil, nil, false) }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return (nil, nil, true) }

        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any] else {
            return (nil, nil, false)
        }

        let content = delta["content"] as? String
        let reasoning = delta["reasoning_content"] as? String
        return (content, reasoning, false)
    }
}
