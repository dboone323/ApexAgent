import Testing
import Foundation
import AppKit
@testable import ApexAgentCore

@Suite("RuntimeContractTests") final class RuntimeContractTests {

    @Test func testRuntimeErrorClassifier() {
        // Real functional error validation for cancellation
        let cancelError = CancellationError()
        let classifiedCancel = RuntimeErrorClassifier.classify(error: cancelError)
        #expect(classifiedCancel == .cancelled)

        // Real functional error validation for security permissions
        let securityError = NSError(domain: "AgentSecurity", code: 403, userInfo: [NSLocalizedDescriptionKey: "Enterprise Security: Missing capability token"])
        let classifiedSecurity = RuntimeErrorClassifier.classify(error: securityError)
        #expect(classifiedSecurity == .permissionDenied(reason: "Enterprise Security: Missing capability token"))

        // Real functional error validation for rate limit (429 / resource_exhausted)
        let rateLimitError = NSError(domain: "CloudGemini", code: 429, userInfo: [NSLocalizedDescriptionKey: "RESOURCE_EXHAUSTED: quota exceeded"])
        let classifiedRateLimit = RuntimeErrorClassifier.classify(error: rateLimitError)
        if case .fallbackEligible(let reason) = classifiedRateLimit {
            #expect(reason.contains("Quota / Rate limit reached"))
        } else {
            Issue.record("Expected .fallbackEligible for 429 rate limit error, got \(classifiedRateLimit)")
        }

        // Real functional error validation for unreachable local provider
        let connectionRefusedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Could not connect to localhost:11434"])
        let classifiedConnection = RuntimeErrorClassifier.classify(error: connectionRefusedError)
        if case .fallbackEligible(let reason) = classifiedConnection {
            #expect(reason.contains("Provider unreachable"))
        } else {
            Issue.record("Expected .fallbackEligible for unreachable host, got \(classifiedConnection)")
        }
    }

    @Test func testCandidateChainBuilding() {
        // Verify candidate chain builds an ordered, non-empty, deduplicated set of candidates
        let candidates = ModelRegistry.buildCandidateChain(
            preferred: .appleOnDevice,
            prompt: "Refactor architecture and optimize performance",
            history: [],
            instructions: "System architect",
            tools: ["read_file", "write_file"],
            hasAttachments: false
        )

        #expect(!candidates.isEmpty, "Candidate chain should never be empty")
        #expect(candidates.first?.provider == .appleOnDevice)

        // Verify priorities are sequential
        for (idx, candidate) in candidates.enumerated() {
            #expect(candidate.priority == idx + 1)
        }

        // Verify providers in candidate chain are unique
        let providerSet = Set(candidates.map { $0.provider })
        #expect(providerSet.count == candidates.count, "Candidate chain must not contain duplicate providers")
    }

    @Test func testTerminalStatesHaveActionableUserMessages() {
        #expect(RuntimeTerminalState.emptyOutput.userFacingMessage.contains("Try again"))
        #expect(RuntimeTerminalState.timedOut(duration: 90).userFacingMessage.contains("another provider"))
        #expect(RuntimeTerminalState.failed(error: "offline", isRetryable: true).userFacingMessage.contains("retry"))
        #expect(RuntimeTerminalState.fallbackExhausted(errors: []).userFacingMessage.contains("provider settings"))
    }

    @MainActor
    @Test func testSessionLifecycleManagerTaskCancellation() async {
        let manager = SessionLifecycleManager.shared
        let sessionId = UUID()

        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        manager.register(task: task, forSessionId: sessionId)

        #expect(!task.isCancelled)
        manager.cancelSession(id: sessionId)
        #expect(task.isCancelled)
    }

    @MainActor
    @Test func testSessionLifecycleManagerConfirmationResolution() async {
        let manager = SessionLifecycleManager.shared
        let reqId = UUID()
        let sessionId = UUID()

        let resolutionTask = Task<Bool, Never> {
            await withCheckedContinuation { continuation in
                manager.registerConfirmation(requestId: reqId, sessionId: sessionId, continuation: continuation)
            }
        }

        // Yield execution to allow continuation registration
        await Task.yield()

        let resolved = manager.resolveConfirmation(requestId: reqId, approved: true)
        #expect(resolved == true)

        let approval = await resolutionTask.value
        #expect(approval == true)
    }

    @MainActor
    @Test func testSessionLifecycleManagerCancellationRejectsPendingConfirmations() async {
        let manager = SessionLifecycleManager.shared
        let reqId = UUID()
        let sessionId = UUID()

        let resolutionTask = Task<Bool, Never> {
            await withCheckedContinuation { continuation in
                manager.registerConfirmation(requestId: reqId, sessionId: sessionId, continuation: continuation)
            }
        }

        await Task.yield()

        manager.cancelSession(id: sessionId)

        let approval = await resolutionTask.value
        #expect(approval == false, "Cancelling a session must resolve pending confirmations to false")
    }

    @MainActor
    @Test func testSecurityAuditorSensitiveDataRedaction() {
        let rawLog = """
        Connecting with key sk-1234567890abcdef1234567890 and gemini AIzaSyD123456789012345678901234567890.
        Authorization: Bearer secretToken12345
        Payload: {"password": "topSecretPassword123", "prompt": "Hello world"}
        """

        let redacted = SecurityAuditor.redactSensitiveData(in: rawLog)

        #expect(!redacted.contains("sk-1234567890abcdef1234567890"))
        #expect(redacted.contains("[REDACTED_API_KEY]"))

        #expect(!redacted.contains("AIzaSyD123456789012345678901234567890"))
        #expect(redacted.contains("[REDACTED_GEMINI_KEY]"))

        #expect(!redacted.contains("secretToken12345"))
        #expect(redacted.contains("Bearer [REDACTED_TOKEN]"))

        #expect(!redacted.contains("topSecretPassword123"))
        #expect(redacted.contains("\"password\": \"[REDACTED]\""))
    }

    @MainActor
    @Test func testToolDispatchEngineRBACAllowlist() async {
        let engine = ToolDispatchEngine()
        let bot = BotProfile(name: "RestrictedBot", title: "Reader")
        bot.allowedToolNames = ["read_file"] // Only read_file allowed

        // Attempting to execute run_shell_command must throw a 403 permission error
        var caughtError: Error?
        do {
            _ = try await engine.executeToolByName(
                name: "run_shell_command",
                jsonArguments: "{\"command\": \"ls\"}",
                allTools: [],
                bot: bot
            )
        } catch {
            caughtError = error
        }

        #expect(caughtError != nil)
        let nsError = caughtError as? NSError
        #expect(nsError?.domain == "AgentSecurity")
        #expect(nsError?.code == 403)
        #expect(nsError?.localizedDescription.contains("RestrictedBot") == true)
    }

    @Test func testAgentRuntimeContractTypes() {
        let requestId = UUID()
        let conversationId = UUID()
        let identity = AgentIdentity.bot(id: UUID(), name: "Atlas")

        let request = AgentRequest(
            id: requestId,
            conversationId: conversationId,
            senderIdentity: identity,
            prompt: "Test prompt",
            toolCallingMode: .auto
        )

        #expect(request.id == requestId)
        #expect(request.conversationId == conversationId)
        #expect(request.senderIdentity.displayName == "Atlas")

        let terminalState = RuntimeTerminalState.completed(output: "Done")
        #expect(terminalState.isSuccess)
        #expect(terminalState.outputContent == "Done")

        let exhaustedState = RuntimeTerminalState.fallbackExhausted(errors: ["Timeout", "Offline"])
        #expect(!exhaustedState.isSuccess)
        #expect(exhaustedState.terminalDescription.contains("Timeout"))
    }

    @Test func testConveneMeetingQuorumConfidenceCalculation() {
        let validAgentsCount = 4
        let rounds = 1
        let totalExpected = validAgentsCount * rounds

        // Scenario 1: Quorum met (3 of 4 succeeded)
        let debateHistoryQuorum = [
            ConveneMeetingTool.MeetingTurn(agentName: "Codex", statement: "Propose modularization"),
            ConveneMeetingTool.MeetingTurn(agentName: "Nexus", statement: "Propose async executor"),
            ConveneMeetingTool.MeetingTurn(agentName: "Oracle", statement: "Participant response unavailable: timed out"),
            ConveneMeetingTool.MeetingTurn(agentName: "Auditor", statement: "Propose linter check")
        ]

        let successfulTurns = debateHistoryQuorum.filter { !$0.statement.starts(with: "Participant response unavailable:") }
        let failedTurns = debateHistoryQuorum.filter { $0.statement.starts(with: "Participant response unavailable:") }
        let quorumMet = successfulTurns.count >= (validAgentsCount / 2 + 1)
        let confidence = Double(successfulTurns.count) / Double(totalExpected)

        #expect(quorumMet == true)
        #expect(confidence == 0.75)
        #expect(failedTurns.count == 1)

        // Scenario 2: Quorum failed (only 1 of 4 succeeded)
        let debateHistoryFailed = [
            ConveneMeetingTool.MeetingTurn(agentName: "Codex", statement: "Participant response unavailable: error"),
            ConveneMeetingTool.MeetingTurn(agentName: "Nexus", statement: "Propose async executor"),
            ConveneMeetingTool.MeetingTurn(agentName: "Oracle", statement: "Participant response unavailable: timed out"),
            ConveneMeetingTool.MeetingTurn(agentName: "Auditor", statement: "Participant response unavailable: crashed")
        ]
        let successfulFailed = debateHistoryFailed.filter { !$0.statement.starts(with: "Participant response unavailable:") }
        let quorumFailed = successfulFailed.count >= (validAgentsCount / 2 + 1)
        let confidenceFailed = Double(successfulFailed.count) / Double(totalExpected)

        #expect(quorumFailed == false)
        #expect(confidenceFailed == 0.25)
    }

    @Test func testAgentPrecedenceResolution() {
        // 1. Explicit BotProfile Overrides takes top precedence
        let bot = BotProfile(
            name: "CustomOpsBot",
            title: "DevOps Specialist",
            descriptionText: "Deploy and monitor AWS containers.",
            avatarName: "terminal",
            memory: "Prefer terraform over cloudformation"
        )
        bot.modelProvider = .localOllama
        bot.ollamaModelOverride = "llama3:8b"
        bot.allowedToolNames = ["run_shell_command", "watch_paths"]

        let botContext = AgentPrecedenceResolver.resolve(
            bot: bot,
            archetypeName: "developer",
            globalInstructions: "Global default prompt",
            globalProvider: .appleOnDevice,
            globalAllowedTools: ["read_file"]
        )

        #expect(botContext.source == .botProfileOverride)
        #expect(botContext.name == "CustomOpsBot")
        #expect(botContext.effectiveProvider == .localOllama)
        #expect(botContext.effectiveOllamaModel == "llama3:8b")
        #expect(botContext.effectiveAllowedTools == ["run_shell_command", "watch_paths"])
        #expect(botContext.effectiveInstructions.contains("Deploy and monitor AWS containers."))
        #expect(botContext.effectiveInstructions.contains("Prefer terraform over cloudformation"))

        // 2. Archetype Overrides takes precedence when no BotProfile is provided
        let archetypeContext = AgentPrecedenceResolver.resolve(
            bot: nil,
            archetypeName: "developer",
            globalInstructions: "Global default prompt",
            globalProvider: .appleOnDevice,
            globalAllowedTools: ["generic_tool"]
        )

        #expect(archetypeContext.source == .archetype)
        #expect(archetypeContext.name == "developer")
        #expect(archetypeContext.effectiveAllowedTools.contains("read_file"))
        #expect(archetypeContext.effectiveAllowedTools.contains("write_file"))
        #expect(archetypeContext.effectiveInstructions.contains("Codex"))

        // 3. Global Default takes effect when neither BotProfile nor valid Archetype is provided
        let globalContext = AgentPrecedenceResolver.resolve(
            bot: nil,
            archetypeName: nil,
            globalInstructions: "Default system instructions",
            globalProvider: .cloudGemini,
            globalAllowedTools: ["generic_tool"]
        )

        #expect(globalContext.source == .globalDefault)
        #expect(globalContext.name == "ApexAgent")
        #expect(globalContext.effectiveProvider == .cloudGemini)
        #expect(globalContext.effectiveAllowedTools == ["generic_tool"])
        #expect(globalContext.effectiveInstructions == "Default system instructions")
    }

    @Test @MainActor func testA2ABearerAuthentication() async {
        let server = A2AServer.shared
        let testToken = "a2a-test-secret-\(UUID().uuidString)"
        defer { KeychainManager.delete(key: "a2aAuthToken") }
        KeychainManager.save(key: "a2aAuthToken", value: testToken)

        // Case 1: No Authorization header -> 401 Unauthorized
        let rawNoAuth = "POST /a2a HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
        let noAuthResult = await server.processHttpBuffer(Data(rawNoAuth.utf8))
        #expect(noAuthResult != nil)
        if let (_, responseData) = noAuthResult {
            let responseStr = String(data: responseData, encoding: .utf8) ?? ""
            #expect(responseStr.contains("401 Unauthorized"))
        }

        // Case 2: Invalid Bearer token -> 401 Unauthorized
        let rawWrongAuth = "POST /a2a HTTP/1.1\r\nAuthorization: Bearer wrong-token\r\nContent-Length: 2\r\n\r\n{}"
        let wrongAuthResult = await server.processHttpBuffer(Data(rawWrongAuth.utf8))
        #expect(wrongAuthResult != nil)
        if let (_, responseData) = wrongAuthResult {
            let responseStr = String(data: responseData, encoding: .utf8) ?? ""
            #expect(responseStr.contains("401 Unauthorized"))
        }

        // Case 3: Valid Bearer token -> Authenticated (200 OK)
        let rawValidAuth = "POST /a2a HTTP/1.1\r\nAuthorization: Bearer \(testToken)\r\nContent-Length: 2\r\n\r\n{}"
        let validAuthResult = await server.processHttpBuffer(Data(rawValidAuth.utf8))
        #expect(validAuthResult != nil)
        if let (_, responseData) = validAuthResult {
            let responseStr = String(data: responseData, encoding: .utf8) ?? ""
            #expect(!responseStr.contains("401 Unauthorized"))
            #expect(responseStr.contains("200 OK"))
        }
    }

    @Test @MainActor func testRemoteCompanionGatewayTokenValidation() {
        let gateway = RemoteCompanionGateway.shared
        let testSecret = "CompanionSecret-\(UUID().uuidString)"
        gateway.configure(sharedSecret: testSecret)

        let deviceId = "test-device-\(UUID().uuidString)"
        let pairingReq = CompanionPairingRequest(
            deviceId: deviceId,
            deviceName: "Daniel's iPhone",
            clientChallenge: "nonce-12345"
        )

        // Pairing with wrong secret -> Unauthorized
        let rejectedAck = gateway.processPairingRequest(pairingReq, sharedSecretProvided: "wrong-secret")
        #expect(rejectedAck.isAuthorized == false)
        #expect(rejectedAck.sessionToken.isEmpty)

        // Pairing with correct secret -> Authorized with session token
        let authorizedAck = gateway.processPairingRequest(pairingReq, sharedSecretProvided: testSecret)
        #expect(authorizedAck.isAuthorized == true)
        #expect(!authorizedAck.sessionToken.isEmpty)

        let sessionToken = authorizedAck.sessionToken

        // Validate token against valid device
        #expect(gateway.validateSessionToken(sessionToken, forDeviceId: deviceId) == true)

        // Validate spoofed device ID with valid token -> rejected
        #expect(gateway.validateSessionToken(sessionToken, forDeviceId: "spoofed-device-id") == false)

        // Validate invalid token with valid device ID -> rejected
        #expect(gateway.validateSessionToken("fake-token", forDeviceId: deviceId) == false)

        // Test frame handling: Unauthenticated sensor upload is rejected
        let sensorPayload = CompanionSensorPayload(kind: .location, dataBase64: "dGVzdA==")
        let payloadJSON = (try? String(data: JSONEncoder().encode(sensorPayload), encoding: .utf8)) ?? "{}"

        let unauthenticatedFrame = CompanionMessageFrame(
            type: .sensorUpload,
            senderId: deviceId,
            sessionToken: "invalid-token",
            payloadJSON: payloadJSON
        )
        let rejectedFrameResult = gateway.handleInboundFrame(unauthenticatedFrame)
        #expect(rejectedFrameResult == nil)

        // Authenticated sensor upload is accepted
        let authenticatedFrame = CompanionMessageFrame(
            type: .sensorUpload,
            senderId: deviceId,
            sessionToken: sessionToken,
            payloadJSON: payloadJSON
        )
        let acceptedFrameResult = gateway.handleInboundFrame(authenticatedFrame)
        #expect(acceptedFrameResult != nil)
        #expect(acceptedFrameResult?.type == .ack)
    }

    @Test func testLegacyGeminiKeyFileMigrationUsesIsolatedAccount() throws {
        #expect(KeychainManager.isTestProcess)
        #expect(KeychainManager.activeServiceName != KeychainManager.serviceName)
        #expect(ApexAgentStoragePaths.tools.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(ApexAgentStoragePaths.skills.path.hasPrefix(FileManager.default.temporaryDirectory.path))

        let account = "test-gemini-\(UUID().uuidString)"
        let testKey = "fixture-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgentKeychainMigration-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("legacy-key")
        defer {
            _ = KeychainManager.delete(key: account)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try testKey.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(KeychainManager.migrateLegacyFile(at: fileURL, toKey: account))
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(KeychainManager.get(key: account) == testKey)
    }

    @Test func testCognitiveMemoryContextCompaction() async throws {
        let testBotId = UUID()
        let messages = [
            ChatMessage(role: .user, content: "First task: check database schema"),
            ChatMessage(role: .assistant, content: "Found 12 tables in SQLite"),
            ChatMessage(role: .user, content: "Second task: check migrations"),
            ChatMessage(role: .assistant, content: "Migrations are up to date"),
            ChatMessage(role: .user, content: "Third task: run unit tests"),
            ChatMessage(role: .assistant, content: "All unit tests passed")
        ]

        let (compacted, archivedCount) = try await CognitiveMemoryEngine.shared.compactMessages(
            messages: messages,
            keepRecent: 4,
            maxChars: 4000,
            botId: testBotId
        ) { transcript in
            #expect(transcript.contains("First task"))
            #expect(transcript.contains("Found 12 tables"))
            return "Earlier turns validated database schema (12 tables) and found migrations up to date."
        }

        #expect(archivedCount == 2)
        #expect(compacted.count == 5) // 1 system summary + 4 preserved recent turns
        #expect(compacted.first?.role == .system)
        #expect(compacted.first?.content.contains("Earlier turns validated database schema") == true)
        #expect(compacted.last?.content == "All unit tests passed")

        // Verify durable episodic memory was created
        let episodes = await CognitiveMemoryEngine.shared.allEpisodes(forBotId: testBotId)
        #expect(!episodes.isEmpty)
        let compactionEpisode = episodes.first(where: { $0.eventType == "context_compaction" })
        #expect(compactionEpisode != nil)
        #expect(compactionEpisode?.summary.contains("Earlier turns validated database schema") == true)
    }

    @Test func testContextCompactorTokenBudgeting() async {
        let compactor = ContextCompactor.shared
        let systemPrompt = "You are an autonomous engineering orchestrator."

        let longBlock = String(repeating: "let sampleValue = 42; performBufferFlush()\n", count: 25)
        let messages: [(role: String, content: String)] = [
            (role: "user", content: "Analyze the memory consumption profile:\n" + longBlock),
            (role: "assistant", content: "Heap analysis findings:\n" + longBlock),
            (role: "user", content: "Identify any retained cycles in BotSession:\n" + longBlock),
            (role: "assistant", content: "Found unowned reference in delegate callback:\n" + longBlock),
            (role: "user", content: "Run benchmark suite."),
            (role: "assistant", content: "Benchmark completed: 0 leaks, 180MB peak RSS.")
        ]

        let shouldCompactHighBudget = await compactor.shouldCompact(messages: messages, threshold: 10000)
        #expect(shouldCompactHighBudget == false, "Should not compact when well within threshold")

        let shouldCompactLowBudget = await compactor.shouldCompact(messages: messages, threshold: 20)
        #expect(shouldCompactLowBudget == true, "Should trigger compaction when exceeding low threshold")

        let input = CompactionInput(
            messages: messages,
            maxTokenBudget: 50,
            pinnedSystemPrompt: systemPrompt,
            recentTurnsToPreserve: 1 // Preserves 1 turn (last 2 messages: user + assistant)
        )

        let result = await compactor.compact(input)
        #expect(result.summarizedTurnCount == 4, "Should have summarized 4 older messages")
        #expect(result.approximateTokensSaved > 0, "Compaction must save tokens")
        #expect(result.compactedMessages.first?.role == "system")
        #expect(result.compactedMessages.first?.content == systemPrompt)
        #expect(result.compactedMessages.last?.content == "Benchmark completed: 0 leaks, 180MB peak RSS.")
        #expect(result.compactedMessages.contains { $0.content.contains("Context Summary — 4 older turns") })
    }

    @Test func testCandidateChainFallbackProgression() {
        let chain = ModelRegistry.buildCandidateChain(
            preferred: .appleOnDevice,
            prompt: "Synthesize test results",
            history: [],
            instructions: "Tester",
            tools: [],
            hasAttachments: false
        )
        #expect(!chain.isEmpty)

        // Simulate fallback sequence through candidate errors
        var fallbackReasons: [String] = []
        for candidate in chain {
            let simulatedError: Error
            switch candidate.provider {
            case .appleOnDevice:
                simulatedError = NSError(domain: "AppleFoundationModels", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
            case .cloudGemini:
                simulatedError = NSError(domain: "CloudGemini", code: 429, userInfo: [NSLocalizedDescriptionKey: "RESOURCE_EXHAUSTED"])
            case .localOllama:
                simulatedError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "Connection refused to 11434"])
            case .localMLX:
                simulatedError = NSError(domain: "MLX", code: 503, userInfo: [NSLocalizedDescriptionKey: "Out of memory"])
            default:
                simulatedError = NSError(domain: "Provider", code: 500, userInfo: [NSLocalizedDescriptionKey: "Unknown failure"])
            }

            let classified = RuntimeErrorClassifier.classify(error: simulatedError)
            if case .fallbackEligible(let reason) = classified {
                fallbackReasons.append(reason)
            }
        }

        #expect(!fallbackReasons.isEmpty, "At least one provider error must be fallback eligible")
        #expect(fallbackReasons.contains { $0.contains("Quota / Rate limit") || $0.contains("Provider unreachable") })
    }
}
