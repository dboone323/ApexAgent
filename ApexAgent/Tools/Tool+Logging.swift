import Foundation
import FoundationModels
import os

extension Tool {
    /// Executes the tool logic with built-in start/end event logging and safety confirmation gates.
    func executeWithLogging(
        arguments: Any,
        orchestrator: OrchestratorProvider,
        riskDescription: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        filePath: String? = nil,
        body: () async throws -> String
    ) async throws -> String {
        let toolName = self.name
        let argsString = String(describing: arguments)
        let signpostID = AgentSignpost.begin("ToolCall", detail: toolName)
        defer { AgentSignpost.end("ToolCall", signpostID, detail: toolName) }
        Logger.tools.debug("Tool called: \(toolName, privacy: .public)")

        // Check for infinite tool loops with RepeatDetector
        if let repeatWarning = await orchestrator.orchestrator.checkRepeat(tool: toolName, arguments: argsString) {
            await orchestrator.orchestrator.logToolEnd(name: toolName, result: repeatWarning, status: .failed("Loop detected"))
            return repeatWarning
        }

        // Check if tool calling mode is disabled
        let isToolDisabled = await MainActor.run {
            orchestrator.orchestrator.toolCallingMode == .disabled
        }
        if isToolDisabled {
            let disabledMsg = "Tool execution rejected: Tool calling mode is disabled."
            await MainActor.run {
                orchestrator.orchestrator.logToolEnd(name: toolName, result: disabledMsg, status: .denied)
            }
            return disabledMsg
        }

        // Log starting of the tool
        await orchestrator.orchestrator.logToolStart(name: toolName, arguments: argsString)

        let overLimit = await MainActor.run {
            let limit = 20
            return orchestrator.orchestrator.activeTurnToolCallCount > limit
        }
        if overLimit {
            let limit = 20
            let limitMsg = "ERROR: Maximum tool calls (\(limit)) reached for this turn to prevent context window overflow."
            await MainActor.run {
                orchestrator.orchestrator.logToolEnd(name: toolName, result: limitMsg, status: .failed("Tool call limit reached"))
            }
            return limitMsg
        }

        // Check if user confirmation is required (safety gate)
        // Skip if the orchestrator already performed confirmation in its
        // executeToolByName wrapper — prevents a double prompt for the
        // MLX/Ollama engine paths.
                let needsConfirm = await MainActor.run {
            !orchestrator.orchestrator.confirmationPerformed
                && orchestrator.orchestrator.shouldConfirmTool(name: toolName)
        }
        if needsConfirm {
            Logger.security.warning("High-risk tool requested: \(toolName, privacy: .public)")
            await orchestrator.orchestrator.updateToolStatus(name: toolName, status: .awaitingConfirmation)
            let approved = await orchestrator.orchestrator.requestConfirmation(
                toolName: toolName,
                arguments: argsString,
                riskDescription: riskDescription ?? "Potentially risky system operation",
                oldContent: oldContent,
                newContent: newContent,
                filePath: filePath
            )

            if !approved {
                await orchestrator.orchestrator.logToolEnd(name: toolName, result: "Operation denied by user.", status: .denied)
                await AgentAuditLog.shared.record(toolName: toolName, arguments: argsString, wasConfirmed: false, status: "denied")
                return "ERROR: Operation denied by user."
            }
        }

        // Set status to running once approved
        await orchestrator.orchestrator.updateToolStatus(name: toolName, status: .running)

        do {
            var result = try await body()

            // Centralized Tool Output Truncation to optimize token usage and prevent
            // DecoderModelError context exhaustion on on-device models.
            let maxLength = 3000
            if result.count > maxLength {
                result = String(result.prefix(maxLength)) + "\n\n[... output truncated at \(maxLength) characters to stay within context budget ...]"
            }

            // Indirect prompt-injection defense: tool results are untrusted
            // content (web pages, files, command output) that can contain
            // instructions aimed at the model ("ignore previous instructions",
            // "you are now...", embedded system-prompt text). Strip directive
            // phrasing before the result re-enters the transcript so a tool
            // cannot hijack the agent loop.
            result = sanitizeForPromptInjection(result)

            if result.hasPrefix("ERROR:") {
                await orchestrator.orchestrator.logToolEnd(name: toolName, result: result, status: .failed(result))
                await AgentAuditLog.shared.record(toolName: toolName, arguments: argsString, wasConfirmed: needsConfirm, status: "failed")
                return result
            }

            await orchestrator.orchestrator.logToolEnd(name: toolName, result: result, status: .success)
            await AgentAuditLog.shared.record(toolName: toolName, arguments: argsString, wasConfirmed: needsConfirm, status: "success")
            return result
        } catch {
            let errorMsg = "ERROR: \(error.localizedDescription)"
            await orchestrator.orchestrator.logToolEnd(name: toolName, result: errorMsg, status: .failed(error.localizedDescription))
            await AgentAuditLog.shared.record(toolName: toolName, arguments: argsString, wasConfirmed: needsConfirm, status: "failed")
            return errorMsg
        }
    }
}

struct AnyExecutableTool: Sendable {
    let name: String
    let schemaJSON: String?
    private let _execute: @Sendable (String) async throws -> String

    init<T: Tool>(_ tool: T) where T.Arguments: Decodable, T.Output == String, T: Sendable {
        self.name = tool.name
        self._execute = { jsonArguments in
            let decoder = JSONDecoder()
            guard let data = jsonArguments.data(using: .utf8) else {
                throw NSError(domain: "Tool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON arguments"])
            }
            let args = try decoder.decode(T.Arguments.self, from: data)
            return try await tool.call(arguments: args)
        }
        
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(tool.parameters),
           let jsonStr = String(data: data, encoding: .utf8) {
            // Reconstruct tool schema JSON with name/description
            let dict: [String: Any] = [
                "name": tool.name,
                "description": tool.description,
                "parameters": (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            ]
            if let finalData = try? JSONSerialization.data(withJSONObject: dict),
               let finalStr = String(data: finalData, encoding: .utf8) {
                self.schemaJSON = finalStr
            } else {
                self.schemaJSON = jsonStr
            }
        } else {
            self.schemaJSON = nil
        }
    }

    @ToolActor
    func execute(jsonArguments: String) async throws -> String {
        return try await _execute(jsonArguments)
    }
}

// MARK: - Indirect prompt-injection defense

/// Tool results (web pages, files, shell output) are untrusted. A malicious or
/// careless source can embed directive text ("ignore previous instructions",
/// "you are now…", fenced system prompts) intended to hijack the agent loop.
/// This neutralizes the most common patterns before the result re-enters the
/// model transcript. It does not destroy content — it wraps/marks directive
/// phrasing so the model treats it as data, not as instructions.
func sanitizeForPromptInjection(_ text: String) -> String {
    func makeRegex(_ pattern: String) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: [])) ?? NSRegularExpression()
    }

    var out = text
    let patterns: [(NSRegularExpression, String)] = [
        // "ignore previous/all instructions" / "disregard the above"
        (makeRegex(#"(?i)\b(ignore|disregard|forget)\b.{0,40}\b(previous|prior|above|all|earlier)\b.{0,20}\b(instructions?|prompt|context|rules?)\b"#), "[PROMPT-INJECTION-FLAGGED: instruction-override attempt removed]"),
        // "you are now / you are an" role hijack
        (makeRegex(#"(?i)\byou (are|are now|will be) now\b.{0,60}\b(ai|assistant|model|agent|bot|helpful|harmless)\b"#), "[PROMPT-INJECTION-FLAGGED: role-redefinition attempt removed]"),
        // "system prompt" / "new system message" injection
        (makeRegex(#"(?i)\b(new |updated )?system (prompt|message|instruction)\b"#), "[PROMPT-INJECTION-FLAGGED: system-prompt injection attempt removed]"),
        // direct command to the assistant
        (makeRegex(#"(?i)\b(please |now )?(respond|reply|act|pretend|reveal|output|print) (as|with|only|exactly)\b"#), "[PROMPT-INJECTION-FLAGGED: directive attempt removed]")
    ]
    for (regex, replacement) in patterns {
        let range = NSRange(out.startIndex..., in: out)
        out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: replacement)
    }
    // Neutralize fenced system-prompt blocks that try to masquerade as instructions.
    if out.contains("```system") || out.contains("``` System") {
        out = out.replacingOccurrences(of: "```system", with: "```[flagged-system-block]")
                     .replacingOccurrences(of: "``` System", with: "```[flagged-system-block]")
    }
    return out
}
