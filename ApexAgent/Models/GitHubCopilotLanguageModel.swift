import Foundation
import FoundationModels
import AppKit

// MARK: - GitHub Copilot Token Manager
//
// Manages authentication and session tokens for GitHub Copilot.
// Discovers GitHub tokens via `gh auth token`, environment variables,
// `~/.config/github-copilot/hosts.json`, or Settings, then exchanges them
// for Copilot session tokens via `https://api.github.com/copilot_internal/v2/token`.

public actor GitHubCopilotTokenManager {
    public static let shared = GitHubCopilotTokenManager()

    private struct CachedToken {
        let sessionToken: String
        let expiresAt: Date
        let endpoint: String
    }

    private var cachedToken: CachedToken?

    public init() {}

    /// Exposes the expiration date of the currently cached session token, if any.
    public var cachedExpiry: Date? {
        cachedToken?.expiresAt
    }

    /// Retrieves an active Copilot session token, refreshing if expired.
    public func getSessionToken() async throws -> String {
        if let cached = cachedToken, cached.expiresAt.timeIntervalSinceNow > 180 {
            return cached.sessionToken
        }

        let gitHubToken = try await resolveGitHubToken()
        let session = try await exchangeGitHubTokenForSession(gitHubToken: gitHubToken)
        self.cachedToken = session
        return session.sessionToken
    }

    /// Resolves the underlying GitHub token from various local sources.
    public func resolveGitHubToken() async throws -> String {
        // 1. Check user-configured token in UserDefaults
        if let manualToken = UserDefaults.standard.string(forKey: "apex.model.copilotToken")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !manualToken.isEmpty {
            return manualToken
        }

        // 2. Check environment variables
        let env = ProcessInfo.processInfo.environment
        if let envToken = env["GITHUB_COPILOT_TOKEN"] ?? env["GITHUB_TOKEN"],
           !envToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. Check ~/.config/github-copilot/hosts.json
        let configPath = ("~/.config/github-copilot/hosts.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (_, val) in json {
                if let dict = val as? [String: Any], let oauthToken = dict["oauth_token"] as? String, !oauthToken.isEmpty {
                    return oauthToken
                }
            }
        }

        // 4. Check `gh auth token` via CLI Process
        if let token1 = try? await runCLICommand(path: "/opt/homebrew/bin/gh", args: ["auth", "token"]) {
            let clean = token1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains(" ") {
                return clean
            }
        }
        if let token2 = try? await runCLICommand(path: "/usr/local/bin/gh", args: ["auth", "token"]) {
            let clean = token2.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty && !clean.contains(" ") {
                return clean
            }
        }

        throw NSError(
            domain: "GitHubCopilotLanguageModel",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "GitHub Copilot authentication required. Run `gh auth login` in Terminal, configure apex.model.copilotToken in Settings, or set GITHUB_COPILOT_TOKEN."]
        )
    }

    private func exchangeGitHubTokenForSession(gitHubToken: String) async throws -> CachedToken {
        guard let url = URL(string: "https://api.github.com/copilot_internal/v2/token") else {
            throw NSError(domain: "GitHubCopilotLanguageModel", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid token exchange URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(gitHubToken)", forHTTPHeaderField: "Authorization")
        request.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.17.0", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.17.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GitHubCopilotLanguageModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Non-HTTP response during Copilot token exchange"])
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "GitHubCopilotLanguageModel", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to exchange GitHub token for Copilot session (\(httpResponse.statusCode)): \(errorText)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionToken = json["token"] as? String else {
            throw NSError(domain: "GitHubCopilotLanguageModel", code: 500, userInfo: [NSLocalizedDescriptionKey: "Malformed response during Copilot token exchange"])
        }

        let expiresAtEpoch = (json["expires_at"] as? Double) ?? (Date().timeIntervalSince1970 + 1800)
        let endpoints = json["endpoints"] as? [String: Any]
        let apiEndpoint = (endpoints?["api"] as? String) ?? "https://api.githubcopilot.com"

        return CachedToken(
            sessionToken: sessionToken,
            expiresAt: Date(timeIntervalSince1970: expiresAtEpoch),
            endpoint: apiEndpoint
        )
    }

    private func runCLICommand(path: String, args: [String]) async throws -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - GitHub Copilot Configuration

public struct GitHubCopilotConfiguration: Hashable, Sendable, Codable, Equatable {
    public var endpointURL: URL
    public var modelName: String
    public var temperature: Double?
    public var maxTokens: Int?

    public init(
        endpointURL: URL = URL(string: "https://api.githubcopilot.com/chat/completions")!,
        modelName: String = "gpt-4o",
        temperature: Double? = 0.7,
        maxTokens: Int? = 4096
    ) {
        self.endpointURL = endpointURL
        self.modelName = modelName
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - GitHub Copilot Language Model

public struct GitHubCopilotLanguageModel: LanguageModel {
    public typealias Executor = GitHubCopilotLanguageModelExecutor

    public let configuration: GitHubCopilotConfiguration

    public var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling, .reasoning])
    }

    public var executorConfiguration: GitHubCopilotLanguageModelExecutor.Configuration {
        GitHubCopilotLanguageModelExecutor.Configuration(configuration: configuration)
    }

    public init(configuration: GitHubCopilotConfiguration = GitHubCopilotConfiguration()) {
        self.configuration = configuration
    }

    public func formatCopilotConfigurationMarkdown() -> String {
        var md = "### 🐙 GitHub Copilot Language Model Telemetry\n\n"
        md += "| Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Endpoint | `\(configuration.endpointURL.absoluteString)` | Copilot chat completions REST API |\n"
        md += "| Model Name | `\(configuration.modelName)` | Target engine (gpt-4o, claude-3.5-sonnet, o1) |\n"
        md += "| Integration | VS Code / Copilot Chat | Pure Swift SSE Wire Protocol |\n"
        md += "| Capabilities | Tool Calling, Reasoning | Multi-modal FoundationModels |\n"
        return md
    }
}

// MARK: - GitHub Copilot Executor

public struct GitHubCopilotLanguageModelExecutor: LanguageModelExecutor, DynamicToolRouting {
    public typealias Model = GitHubCopilotLanguageModel

    public struct Configuration: Hashable, Sendable {
        public let configuration: GitHubCopilotConfiguration
    }

    public let configuration: Configuration

    public init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    public func prewarm(model: GitHubCopilotLanguageModel, transcript: Transcript) {}

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

    public func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: GitHubCopilotLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        let sessionToken = try await GitHubCopilotTokenManager.shared.getSessionToken()
        let config = configuration.configuration

        // 1. Build messages
        var messages: [[String: Any]] = []
        for entry in request.transcript {
            switch entry {
            case .instructions(let inst):
                var text = ""
                for seg in inst.segments {
                    if case .text(let t) = seg { text += t.content }
                }
                messages.append(["role": "system", "content": text])

            case .prompt(let prompt):
                var text = ""
                for seg in prompt.segments {
                    if case .text(let t) = seg { text += t.content }
                }
                messages.append(["role": "user", "content": text])

            case .response(let resp):
                var text = ""
                for seg in resp.segments {
                    if case .text(let t) = seg { text += t.content }
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
                for seg in toolOutput.segments {
                    if case .text(let t) = seg { text += t.content }
                }
                messages.append([
                    "role": "tool",
                    "tool_call_id": "call_0",
                    "content": text
                ])

            case .reasoning(let reasoning):
                var text = ""
                for seg in reasoning.segments {
                    if case .text(let t) = seg { text += t.content }
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

        // 2. Fetch tools
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
        if let temp = config.temperature { requestDict["temperature"] = temp }
        if let maxT = config.maxTokens { requestDict["max_tokens"] = maxT }
        if !toolsPayload.isEmpty {
            requestDict["tools"] = toolsPayload
            requestDict["tool_choice"] = (request.generationOptions.toolCallingMode == .required) ? "required" : "auto"
        }

        let bodyData = try JSONSerialization.data(withJSONObject: requestDict)

        // 4. Send request
        var urlRequest = URLRequest(url: config.endpointURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("vscode/1.90.0", forHTTPHeaderField: "Editor-Version")
        urlRequest.setValue("copilot-chat/0.17.0", forHTTPHeaderField: "Editor-Plugin-Version")
        urlRequest.setValue("vscode-chat", forHTTPHeaderField: "Copilot-Integration-Id")
        urlRequest.setValue("GitHubCopilotChat/0.17.0", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = bodyData

        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GitHubCopilotLanguageModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from Copilot API"])
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "GitHubCopilotLanguageModel", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Copilot API returned HTTP \(httpResponse.statusCode)"])
        }

        // 5. Parse SSE Stream
        let entryID = UUID().uuidString
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix(":") { continue }
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let lineData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
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
