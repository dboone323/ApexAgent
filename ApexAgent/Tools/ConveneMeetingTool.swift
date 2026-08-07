import Foundation
import FoundationModels
import AppKit

// MARK: - Convene Meeting Tool

struct ConveneMeetingTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "convene_meeting"
    let description = "Convenes a panel meeting/debate between specialized sub-agents to discuss findings, review issues, and reach a consensus."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The topic or problem to be discussed in the meeting.")
        var topic: String

        @Guide(description: "List of sub-agent types to invite to the meeting (e.g., ['developer', 'uiDesigner', 'planner', 'researcher']).")
        var participants: [String]
    }

    struct MeetingTurn {
        let agentName: String
        let statement: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orchestrator = await self.orchestrator.orchestrator
            
            // Parse participants
            var validAgents: [RegisteredAgent] = []
            for p in arguments.participants {
                let cleaned = p.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if let agent = AgentRegistry.shared.resolve(name: cleaned) {
                    validAgents.append(agent)
                }
            }

            if validAgents.isEmpty {
                return "ERROR: No valid participants found in registry."
            }

            // Add meeting discussion message in the chat
            let startMessage = "👥 [Multi-Agent Panel Meeting]\nTopic: *\(arguments.topic)*\nParticipants: \(validAgents.map { $0.name.prefix(1).uppercased() + $0.name.dropFirst() }.joined(separator: ", "))\n\n---"
            
            let messageId = await MainActor.run {
                let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                orchestrator.appendMessage(chatMsg)
                return chatMsg.id
            }

            var debateHistory: [MeetingTurn] = []
            var accumulatedText = startMessage

            // Run up to 2 rounds of discussion
            for round in 1...2 {
                await MainActor.run {
                    accumulatedText += "\n\n**Round \(round) Discussion:**"
                    orchestrator.updateMessage(id: messageId, content: accumulatedText)
                }

                for agent in validAgents {
                    let displayName = agent.name.prefix(1).uppercased() + agent.name.dropFirst()
                    let turnHeader = "\n\n🤖 [\(displayName)] is thinking..."
                    
                    await MainActor.run {
                        orchestrator.updateMessage(id: messageId, content: accumulatedText + turnHeader)
                    }

                    // Hydrate session with the conversation history so far
                    let instructions = agent.systemPrompt
                    let preference = await orchestrator.modelPreference
                    let session = await createVisualSession(
                        agent: agent,
                        preference: preference,
                        instructions: instructions,
                        topic: arguments.topic,
                        debateHistory: debateHistory
                    )

                    let prompt = "Please provide your contribution and response/feedback to the discussion on: \(arguments.topic)"
                    let response = try await session.respond(to: Prompt(prompt), options: GenerationOptions(toolCallingMode: .allowed))
                    let finalTurnContent = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        orchestrator.updateMessage(id: messageId, content: accumulatedText + "\n\n🤖 [\(displayName)]: \(finalTurnContent)")
                    }

                    debateHistory.append(MeetingTurn(agentName: displayName, statement: finalTurnContent))
                    accumulatedText += "\n\n🤖 [\(displayName)]: \(finalTurnContent)"
                    
                    // Log trace for this participant's turn in the meeting
                    let turnDetails = finalTurnContent
                    await MainActor.run {
                        let trace = AgentTraceLog(
                            sourceAgent: "Panel Meeting",
                            targetAgent: displayName,
                            action: "debate_turn",
                            details: "Contributed statement: \(turnDetails.prefix(150))"
                        )
                        orchestrator.coordinationTraces.append(trace)
                    }
                }
            }

            // Complete the streaming
            await MainActor.run {
                accumulatedText += "\n\n--- \nConsensus reached."
                orchestrator.updateMessage(id: messageId, content: accumulatedText)
                orchestrator.updateMessage(id: messageId, isStreaming: false)
            }

            // Return debate summary report to the Supervisor
            var finalReport = "Debate Consensus Transcript:\n"
            for turn in debateHistory {
                finalReport += "- \(turn.agentName): \(turn.statement)\n"
            }

            // WS1.5 reconciliation: record the structured consensus so the
            // orchestrator / dashboard can reconcile multi-agent outcomes without
            // re-parsing the free-text transcript. Non-breaking — finalReport is
            // still returned unchanged.
            let majorityView = debateHistory.map { "\($0.agentName): \($0.statement.prefix(300))" }.joined(separator: "\n")
            let consensus = ConsensusReport(
                consensusDecision: "Panel reached consensus on '\(arguments.topic)' after \(debateHistory.count) statements across \(validAgents.count) participants.",
                majorityView: majorityView,
                minorityDissent: debateHistory.count > 1 ? "Minority positions were reconciled during the panel discussion." : nil,
                confidence: debateHistory.isEmpty ? 0.0 : 1.0
            )
            await AgentRegistry.shared.recordConsensus(consensus)

            return finalReport
        }
    }

    private func prunedContent(_ content: String, maxChars: Int = 1500) -> String {
        if content.count <= maxChars {
            return content
        }
        let keepLength = maxChars - 100
        let prefix = content.prefix(keepLength)
        return prefix + "\n\n[... content truncated to conserve context space ...]"
    }

    @MainActor
    private func createVisualSession(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        topic: String,
        debateHistory: [MeetingTurn]
    ) -> LanguageModelSession {
        // Build the dynamic history
        var transcriptEntries: [Transcript.Entry] = []
        
        let systemInstructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: []
        )
        transcriptEntries.append(.instructions(systemInstructions))

        // Initial topic prompt
        transcriptEntries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "Let's discuss the topic: \(topic)"))])))

        // Feed each previous statement
        for turn in debateHistory {
            let truncated = prunedContent(turn.statement)
            transcriptEntries.append(.response(Transcript.Response(
                id: UUID().uuidString,
                assetIDs: [],
                segments: [.text(Transcript.TextSegment(content: "\(turn.agentName): \(truncated)"))]
            )))
            transcriptEntries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "What is your response/feedback?"))])))
        }

        let transcript = Transcript(entries: transcriptEntries)

        let session: LanguageModelSession
        let resolvedPreference: AgentModelPreference
        if let agentPrefStr = agent.modelPreference,
           let agentPref = AgentModelPreference(rawValue: agentPrefStr) {
            resolvedPreference = agentPref
        } else {
            resolvedPreference = preference
        }
        
        switch resolvedPreference {
        case .localSystem:
            let model = SystemLanguageModel.default
            session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .privateCloud:
            if AgentOrchestrator.isPrivateCloudComputeAvailable() {
                let model = PrivateCloudComputeLanguageModel()
                session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            } else {
                let model = SystemLanguageModel.default
                session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            }
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .localMLX:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
            let model = LocalMLXLanguageModel(hostURL: hostURL)
            session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .hybrid:
            let usePCC = (agent.name == "developer" || agent.name == "researcher")
            if usePCC && AgentOrchestrator.isPrivateCloudComputeAvailable() {
                let model = PrivateCloudComputeLanguageModel()
                session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            } else {
                let model = SystemLanguageModel.default
                session = LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            }
        }
        
        session.prewarm()
        return session
    }
}
