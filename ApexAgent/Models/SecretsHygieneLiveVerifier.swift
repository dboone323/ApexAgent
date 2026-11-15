import Foundation
import FoundationModels

// MARK: - Secrets Hygiene Live Verifier (Issue #108)
//
// Live verification harness demonstrating secrets hygiene across:
// 1. Keychain-backed tool-side injection (credentials resolved at tool boundary, never in prompt/plan)
// 2. Tool output containing fake credentials redacted before entering model context
// 3. Assembled model context guaranteed secret-free
// 4. Persisted trace JSON + replay output carrying zero secret values

@MainActor
public enum SecretsHygieneLiveVerifier {

    public struct VerificationResult: Sendable {
        public let output: String
        public let passed: Bool
        public let tracePath: String
        public let traceSize: Int
        public let redactedFieldsCount: Int
    }

    public static func runVerification(
        workspacePath: String? = nil,
        jsonOutput: Bool = false
    ) async -> VerificationResult {
        var logs: [String] = []
        logs.append("================================================================================")
        logs.append("APEXAGENT ISSUE #108: LIVE SECRETS HYGIENE VERIFICATION (H4)")
        logs.append("Timestamp: \(ISO8601DateFormatter().string(from: Date()))")
        logs.append("================================================================================")

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("ApexAgent-SecretsHygiene-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let effectiveWS = workspacePath ?? tempDir.path

        logs.append("\n[1] Workspace Initialized: \(effectiveWS)")

        let orchestrator = AppDelegate.sharedOrchestrator
        orchestrator.currentWorkspacePath = effectiveWS
        let prevBypass = orchestrator.bypassConfirmationInDebug
        orchestrator.bypassConfirmationInDebug = true
        defer {
            orchestrator.bypassConfirmationInDebug = prevBypass
            try? fm.removeItem(at: tempDir)
        }

        // Test credentials (clearly fake placeholders)
        let fakeDiscordWebhook = "https://discord.com/api/webhooks/1234567890/sk-fake-discord-webhook-secret-token-12345"
        let fakeOpenAIKey = "sk-test-fake-1234-openai-secret-token"
        let fakeAnthropicKey = "sk-ant-api03-fake-anthropic-secret-token-12345"
        let fakeGithubToken = "ghp_1234567890ABCDEFGHIJKLMNO"
        let fakeAwsKey = "AKIAIOSFODNN7EXAMPLE"
        let fakeTavilyKey = "tvly-fake-secret-tavily-key-12345"
        let fakeBraveKey = "BSA1234567890abcdefghijklmnopqrstuvwxyz"
        let fakeDbPassword = "supersecretpassword123"

        // ─────────────────────────────────────────────────────────────────────
        // 1. Keychain-Backed Tool-Side Injection
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[2] Verifying Keychain-Backed Tool-Side Injection:")
        // Save fake credentials into Keychain
        KeychainManager.save(key: "discordWebhookUrl", value: fakeDiscordWebhook)
        KeychainManager.save(key: "tavilyAPIKey", value: fakeTavilyKey)
        KeychainManager.save(key: "braveSearchAPIKey", value: fakeBraveKey)
        defer {
            KeychainManager.delete(key: "discordWebhookUrl")
            KeychainManager.delete(key: "tavilyAPIKey")
            KeychainManager.delete(key: "braveSearchAPIKey")
        }

        let discordTool = DiscordWebhookTool(orchestrator: orchestrator)
        let resolvedWebhook = discordTool.getWebhookUrl()
        let webSearchTool = WebSearchTool(orchestrator: orchestrator)
        let resolvedTavily = webSearchTool.getTavilyAPIKey()
        let resolvedBrave = webSearchTool.getBraveAPIKey()

        let injectionToolSideSuccess = (resolvedWebhook == fakeDiscordWebhook)
            && (resolvedTavily == fakeTavilyKey)
            && (resolvedBrave == fakeBraveKey)

        logs.append("  -> Tool-side Keychain resolution:")
        logs.append("     - DiscordWebhookTool.getWebhookUrl(): resolved from Keychain (configured=\(injectionToolSideSuccess))")
        logs.append("     - WebSearchTool.getTavilyAPIKey(): resolved from Keychain (configured=\(resolvedTavily == fakeTavilyKey))")
        logs.append("     - WebSearchTool.getBraveAPIKey(): resolved from Keychain (configured=\(resolvedBrave == fakeBraveKey))")

        // Verify model plan refers to tool by name only, without credentials
        let planArgs = DiscordWebhookTool.Arguments(message: "Deployment complete to production environment")
        let planArgsString = String(describing: planArgs)
        let planContainsNoSecret = !planArgsString.contains("sk-") && !planArgsString.contains("webhooks")
        logs.append("  -> Tool call arguments in plan/prompt: \"\(planArgsString)\"")
        logs.append("     - Value contains NO secrets: \(planContainsNoSecret ? "PASS" : "FAIL")")

        // ─────────────────────────────────────────────────────────────────────
        // 2. Tool Output Containing Fake Credential Redacted
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[3] Verifying Tool Output Credential Redaction:")
        let secretFixtureFile = URL(fileURLWithPath: effectiveWS).appendingPathComponent("environment.env")
        let fixtureContent = """
        # Automated Environment Configuration
        OPENAI_API_KEY=\(fakeOpenAIKey)
        ANTHROPIC_API_KEY=\(fakeAnthropicKey)
        GITHUB_TOKEN=\(fakeGithubToken)
        AWS_ACCESS_KEY_ID=\(fakeAwsKey)
        DATABASE_URL=postgresql://appuser:\(fakeDbPassword)@db.internal:5432/production
        DISCORD_WEBHOOK=\(fakeDiscordWebhook)
        """
        try? fixtureContent.write(to: secretFixtureFile, atomically: true, encoding: .utf8)

        var rawToolOutput = ""
        do {
            rawToolOutput = try await orchestrator.executeToolByName(
                name: "read_file",
                jsonArguments: "{\"path\": \"\(secretFixtureFile.path)\"}"
            )
        } catch {
            rawToolOutput = "ERROR: \(error.localizedDescription)"
        }

        let outputLeakedOpenAI = rawToolOutput.contains(fakeOpenAIKey)
        let outputLeakedAnthropic = rawToolOutput.contains(fakeAnthropicKey)
        let outputLeakedGithub = rawToolOutput.contains(fakeGithubToken)
        let outputLeakedAws = rawToolOutput.contains(fakeAwsKey)
        let outputLeakedDbPass = rawToolOutput.contains(fakeDbPassword)
        let outputLeakedDiscordToken = rawToolOutput.contains("sk-fake-discord-webhook")

        let toolOutputSecretFree = !outputLeakedOpenAI
            && !outputLeakedAnthropic
            && !outputLeakedGithub
            && !outputLeakedAws
            && !outputLeakedDbPass
            && !outputLeakedDiscordToken

        logs.append("  -> Raw file on disk contained 6 secret values.")
        logs.append("  -> Tool 'read_file' returned redacted output:")
        for line in rawToolOutput.components(separatedBy: "\n") {
            logs.append("     \(line)")
        }
        logs.append("  -> Tool output secret-free check: \(toolOutputSecretFree ? "PASS" : "FAIL")")

        // ─────────────────────────────────────────────────────────────────────
        // 3. Assembled Model Context Redaction
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[4] Verifying Assembled Model Context Redaction:")
        let rawInstructions = "System Instructions with accidental secret: \(fakeTavilyKey)"
        let rawPrompt = "User Prompt with accidental secret: \(fakeOpenAIKey) and Bearer \(fakeGithubToken)"
        let rawHistoryMessage = "Prior assistant turn had token: export TOKEN=\(fakeAnthropicKey)"

        let sanitizedInstructions = SecretRedactor.redact(text: rawInstructions)
        let sanitizedPrompt = SecretRedactor.redact(text: rawPrompt)
        let sanitizedHistory = SecretRedactor.redact(text: rawHistoryMessage)

        let contextSecretFree = !sanitizedInstructions.contains(fakeTavilyKey)
            && !sanitizedPrompt.contains(fakeOpenAIKey)
            && !sanitizedPrompt.contains(fakeGithubToken)
            && !sanitizedHistory.contains(fakeAnthropicKey)

        logs.append("  -> Sanitized System Instructions: \"\(sanitizedInstructions)\"")
        logs.append("  -> Sanitized User Prompt:          \"\(sanitizedPrompt)\"")
        logs.append("  -> Sanitized History Content:      \"\(sanitizedHistory)\"")
        logs.append("  -> Model context secret-free check: \(contextSecretFree ? "PASS" : "FAIL")")

        // ─────────────────────────────────────────────────────────────────────
        // 4. Persisted Trace JSON + Replay Carrying No Secret Value
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[5] Verifying Persisted Trace JSON & Replay Redaction:")
        let runId = RunTrace.generateRunId()
        _ = RunTraceManager.shared.startRun(
            runId: runId,
            conversationId: UUID(),
            workspacePath: effectiveWS,
            metadata: ["test": "secrets-hygiene", "apiKey": fakeAnthropicKey]
        )

        // Record tool call with sensitive arguments and result
        RunTraceManager.shared.recordToolCall(
            toolName: "read_file",
            arguments: "{\"path\":\"/secret/key\",\"token\":\"\(fakeGithubToken)\"}",
            result: "key=\(fakeOpenAIKey)",
            status: "success",
            durationMs: 12.5
        )

        // Record model call with sensitive prompt
        RunTraceManager.shared.recordModelCall(
            model: "test-model",
            prompt: "Please review my token \(fakeOpenAIKey)",
            durationMs: 45.0
        )

        RunTraceManager.shared.endRun(runId: runId, status: "completed")

        let traceFileURL = RunTraceStorage.traceFileURL(for: runId, workspacePath: effectiveWS)
        let traceFileExists = fm.fileExists(atPath: traceFileURL.path)
        let traceData = (try? Data(contentsOf: traceFileURL)) ?? Data()
        let traceJSON = String(data: traceData, encoding: .utf8) ?? ""

        let jsonLeakedGithub = traceJSON.contains(fakeGithubToken)
        let jsonLeakedOpenAI = traceJSON.contains(fakeOpenAIKey)
        let jsonLeakedAnthropic = traceJSON.contains(fakeAnthropicKey)

        let traceJSONSecretFree = !jsonLeakedGithub && !jsonLeakedOpenAI && !jsonLeakedAnthropic

        logs.append("  -> Saved Trace File: \(traceFileURL.path)")
        logs.append("  -> Trace File Size:  \(traceData.count) bytes")
        logs.append("  -> Checking raw JSON on disk for secret values:")
        logs.append("     - GITHUB_TOKEN present in JSON:   \(jsonLeakedGithub ? "LEAKED" : "NO (REDACTED)")")
        logs.append("     - OPENAI_KEY present in JSON:     \(jsonLeakedOpenAI ? "LEAKED" : "NO (REDACTED)")")
        logs.append("     - ANTHROPIC_KEY present in JSON:  \(jsonLeakedAnthropic ? "LEAKED" : "NO (REDACTED)")")

        // Quote redacted fields directly from the parsed trace
        var redactedFieldsCount = 0
        if let loadedTrace = try? RunTraceStorage.loadTrace(from: traceFileURL) {
            logs.append("  -> Loaded Trace Events from disk:")
            for ev in loadedTrace.events {
                if let args = ev.argumentsSummary, args.contains("redacted") {
                    redactedFieldsCount += 1
                    logs.append("     [Event #\(ev.sequence) toolCall.argumentsSummary]: \"\(args)\"")
                }
                if let res = ev.resultSummary, res.contains("redacted") {
                    redactedFieldsCount += 1
                    logs.append("     [Event #\(ev.sequence) toolCall.resultSummary]:    \"\(res)\"")
                }
                if let prompt = ev.promptSummary, prompt.contains("redacted") {
                    redactedFieldsCount += 1
                    logs.append("     [Event #\(ev.sequence) modelCall.promptSummary]:   \"\(prompt)\"")
                }
            }
        }

        // Replay verification
        logs.append("\n[6] Trace Replay Output:")
        var replayClean = false
        if let replayReport = try? RunTraceReplayer.replay(fileURL: traceFileURL) {
            let formattedReplay = replayReport.toFormattedString()
            let replayLeakedSecrets = formattedReplay.contains(fakeGithubToken)
                || formattedReplay.contains(fakeOpenAIKey)
                || formattedReplay.contains(fakeAnthropicKey)
            replayClean = !replayLeakedSecrets
            logs.append(formattedReplay)
            logs.append("  -> Replay output secret-free check: \(replayClean ? "PASS" : "FAIL")")
        } else {
            logs.append("  -> Replay execution failed.")
        }

        // ─────────────────────────────────────────────────────────────────────
        // 5. Final Verdict
        // ─────────────────────────────────────────────────────────────────────
        logs.append("\n[7] Verification Verdicts:")
        logs.append("  1. Keychain Tool-Side Injection:     \(injectionToolSideSuccess ? "PASS" : "FAIL")")
        logs.append("  2. Tool Output Credential Redaction:  \(toolOutputSecretFree ? "PASS" : "FAIL")")
        logs.append("  3. Assembled Model Context Redacted: \(contextSecretFree ? "PASS" : "FAIL")")
        logs.append("  4. Persisted Trace JSON Redacted:    \(traceJSONSecretFree ? "PASS" : "FAIL")")
        logs.append("  5. Trace Replay Output Redacted:     \(replayClean ? "PASS" : "FAIL")")

        let allPassed = injectionToolSideSuccess
            && toolOutputSecretFree
            && contextSecretFree
            && traceJSONSecretFree
            && replayClean
            && traceFileExists
            && traceData.count > 0

        logs.append("\nVERDICT: \(allPassed ? "PASSED" : "FAILED")")
        logs.append("================================================================================")

        let outputStr = logs.joined(separator: "\n")
        return VerificationResult(
            output: outputStr,
            passed: allPassed,
            tracePath: traceFileURL.path,
            traceSize: traceData.count,
            redactedFieldsCount: redactedFieldsCount
        )
    }
}
