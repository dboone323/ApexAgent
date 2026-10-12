//
//  AnthropicLanguageModel.swift
//  ApexAgent
//
//  Created for Batch 102: Anthropic Claude Messages API Integration & Wire Auditor.
//

import Foundation
import FoundationModels

// MARK: - Anthropic Configuration

public struct AnthropicModelConfiguration: Sendable, Codable, Equatable, Hashable {
    public var endpointURL: URL
    public var apiKey: String
    public var modelName: String
    public var maxTokens: Int
    public var temperature: Double?
    public var anthropicVersion: String
    public var customHeaders: [String: String]

    public static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let defaultModel = "claude-3-7-sonnet-20250219"
    public static let defaultVersion = "2023-06-01"

    public init(
        endpointURL: URL = defaultEndpoint,
        apiKey: String = "",
        modelName: String = defaultModel,
        maxTokens: Int = 4096,
        temperature: Double? = nil,
        anthropicVersion: String = defaultVersion,
        customHeaders: [String: String] = [:]
    ) {
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.anthropicVersion = anthropicVersion
        self.customHeaders = customHeaders
    }
}

// MARK: - Language Model Conformance

public struct AnthropicLanguageModel: LanguageModel, Sendable {
    public typealias Executor = AnthropicLanguageModelExecutor

    public var configuration: AnthropicModelConfiguration

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    public init(configuration: AnthropicModelConfiguration = AnthropicModelConfiguration()) {
        self.configuration = configuration
    }

    public var executorConfiguration: AnthropicLanguageModelExecutor.Configuration {
        AnthropicLanguageModelExecutor.Configuration(config: configuration)
    }
}

// MARK: - Executor Implementation

public struct AnthropicLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting, Sendable {
    public typealias Model = AnthropicLanguageModel

    public struct Configuration: Hashable, Sendable {
        public let config: AnthropicModelConfiguration
        public init(config: AnthropicModelConfiguration) {
            self.config = config
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: AnthropicLanguageModel, transcript: Transcript) {}

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: AnthropicLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let config = configuration.config
        let effectiveKey = config.apiKey.isEmpty ? (KeychainManager.get(key: "anthropicAPIKey") ?? "") : config.apiKey

        guard !effectiveKey.isEmpty else {
            throw NSError(
                domain: "AnthropicLanguageModel",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "Anthropic API key is missing. Set it via Keychain 'anthropicAPIKey' or configuration."]
            )
        }

        // 1. Convert Transcript to Anthropic Format
        var systemPrompt = ""
        var messages: [[String: Any]] = []

        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                for segment in inst.segments {
                    if case .text(let t) = segment {
                        systemPrompt += t.content
                    }
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
                var blocks: [[String: Any]] = []
                for (idx, call) in toolCalls.enumerated() {
                    let args = call.arguments.toJSONObject()
                    blocks.append([
                        "type": "tool_use",
                        "id": "toolu_\(idx)_\(call.toolName)",
                        "name": call.toolName,
                        "input": args
                    ])
                }
                messages.append(["role": "assistant", "content": blocks])

            case .toolOutput(let toolOutput):
                var text = ""
                for segment in toolOutput.segments {
                    if case .text(let t) = segment {
                        text += t.content
                    }
                }
                messages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": "toolu_0",
                            "content": text
                        ]
                    ]
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

        // 2. Build Request Payload
        var requestDict: [String: Any] = [
            "model": config.modelName,
            "messages": messages,
            "max_tokens": config.maxTokens,
            "stream": true
        ]
        if !systemPrompt.isEmpty {
            requestDict["system"] = systemPrompt
        }
        if let temp = config.temperature {
            requestDict["temperature"] = temp
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestDict)

        // 3. Assemble URLRequest
        var urlRequest = URLRequest(url: config.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(effectiveKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(config.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        for (k, v) in config.customHeaders {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }
        urlRequest.httpBody = bodyData

        // 4. Stream via URLSession
        let session = URLSession(configuration: .default)
        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AnthropicLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            throw NSError(domain: "AnthropicLanguageModel", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(httpResponse.statusCode)"])
        }

        // 5. SSE Accumulation
        let entryID = UUID().uuidString
        for try await rawLine in bytes.lines {
            if let delta = AnthropicSSEParser.parseLine(rawLine) {
                switch delta {
                case .text(let text):
                    await channel.send(LanguageModelExecutorGenerationChannel.Event.response(entryID: entryID, action: .appendText(text, segmentID: nil, tokenCount: 0)))
                case .messageStop:
                    break
                }
            }
        }
    }
}

// MARK: - Anthropic SSE Stream Delta & Parser

public enum AnthropicStreamDelta: Equatable, Sendable {
    case text(String)
    case messageStop
}

public struct AnthropicSSEParser: Sendable {
    public static func parseLine(_ rawLine: String) -> AnthropicStreamDelta? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty,
              let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        switch type {
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let text = delta["text"] as? String,
               !text.isEmpty {
                return .text(text)
            }
            return nil

        case "message_stop":
            return .messageStop

        default:
            return nil
        }
    }
}

// MARK: - Anthropic Wire Protocol & Security Auditor

public struct AnthropicWireViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct AnthropicWireAuditReport: Sendable, Codable, Equatable {
    public let endpointURL: String
    public let modelName: String
    public let anthropicVersion: String
    public let maxTokens: Int
    public let hasAPIKey: Bool
    public let violations: [AnthropicWireViolation]
    public let securityScore: Double

    public var isCompliant: Bool {
        !violations.contains(where: { $0.isFatal })
    }
}

public struct AnthropicWireProtocolAuditor: Sendable {
    public static func auditConfiguration(_ config: AnthropicModelConfiguration) -> AnthropicWireAuditReport {
        var violations: [AnthropicWireViolation] = []

        // 1. Endpoint Scheme Security
        let isLocalhost = (config.endpointURL.host == "localhost" || config.endpointURL.host == "127.0.0.1")
        if config.endpointURL.scheme?.lowercased() != "https" {
            if isLocalhost {
                violations.append(AnthropicWireViolation(
                    code: "LOCAL_HTTP_ALLOWED",
                    message: "Plaintext HTTP endpoint accepted for local proxy development.",
                    isFatal: false
                ))
            } else {
                violations.append(AnthropicWireViolation(
                    code: "INSECURE_REMOTE_HTTP",
                    message: "Remote Anthropic Messages endpoint MUST use TLS (HTTPS) to prevent credential exfiltration.",
                    isFatal: true
                ))
            }
        }

        // 2. API Key Presence
        let hasKey = !config.apiKey.isEmpty || (KeychainManager.get(key: "anthropicAPIKey")?.isEmpty == false)
        if !hasKey {
            violations.append(AnthropicWireViolation(
                code: "MISSING_API_KEY",
                message: "No Anthropic API key configured in configuration or Keychain.",
                isFatal: true
            ))
        }

        // 3. Max Tokens Enforcement (Required by Anthropic)
        if config.maxTokens <= 0 {
            violations.append(AnthropicWireViolation(
                code: "INVALID_MAX_TOKENS",
                message: "Anthropic Messages API requires max_tokens > 0.",
                isFatal: true
            ))
        }

        // 4. Anthropic Version Header
        if config.anthropicVersion.isEmpty {
            violations.append(AnthropicWireViolation(
                code: "MISSING_VERSION_HEADER",
                message: "Anthropic requires 'anthropic-version' header (recommended: 2023-06-01).",
                isFatal: true
            ))
        }

        // 5. Model Name Convention
        if !config.modelName.lowercased().hasPrefix("claude-") {
            violations.append(AnthropicWireViolation(
                code: "NON_STANDARD_MODEL_NAME",
                message: "Anthropic model identifier typically starts with 'claude-'. Specified: '\(config.modelName)'.",
                isFatal: false
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.45) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))

        return AnthropicWireAuditReport(
            endpointURL: config.endpointURL.absoluteString,
            modelName: config.modelName,
            anthropicVersion: config.anthropicVersion,
            maxTokens: config.maxTokens,
            hasAPIKey: hasKey,
            violations: violations,
            securityScore: score
        )
    }

    public static func formatAnthropicConfigurationMarkdown(_ report: AnthropicWireAuditReport) -> String {
        var md = "### 🎭 Anthropic Messages Protocol & Security Audit\n\n"
        md += "| Parameter | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Endpoint | `\(report.endpointURL)` | \(report.isCompliant ? "✅ OK" : "❌ Non-Compliant") |\n"
        md += "| Model | `\(report.modelName)` | 📦 Standard |\n"
        md += "| Anthropic Version | `\(report.anthropicVersion)` | 🏷️ API Version |\n"
        md += "| Max Tokens | `\(report.maxTokens)` | 📊 Budget |\n"
        md += "| API Key Provided | \(report.hasAPIKey ? "✅ Stored" : "❌ Missing") | 🔑 Authentication |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Attention Required") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
