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
    let description = "Convenes a panel meeting/debate between the requested specialized sub-agents to execute the user's concrete topic, review findings, and reach a consensus. Preserve the supplied topic and participants; do not replace a concrete discussion with an agent-status or readiness report."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The topic or problem to be discussed in the meeting.")
        var topic: String

        @Guide(description: "List of sub-agent types to invite to the meeting (e.g., ['developer', 'uiDesigner', 'planner', 'researcher']).")
        var participants: [String]

        enum CodingKeys: String, CodingKey {
            case topic
            case participants
        }

        init(topic: String, participants: [String]) {
            self.topic = topic
            self.participants = participants
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""

            if let list = try? container.decode([String].self, forKey: .participants) {
                self.participants = list
            } else if let stringVal = try? container.decode(String.self, forKey: .participants) {
                let trimmed = stringVal.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                    if let data = trimmed.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode([String].self, from: data) {
                        self.participants = parsed
                    } else {
                        let inner = trimmed.dropFirst().dropLast()
                        self.participants = inner.components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                            .filter { !$0.isEmpty }
                    }
                } else {
                    self.participants = trimmed.components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
                        .filter { !$0.isEmpty }
                }
            } else {
                self.participants = []
            }
        }
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
            let rounds = 2
            for round in 1...rounds {
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

                    let instructions = String(agent.systemPrompt.prefix(1200))
                    let topic = String(arguments.topic.prefix(600))
                    let priorContext = debateHistory.suffix(4).map { "\($0.agentName): \(prunedContent($0.statement, maxChars: 400))" }.joined(separator: "\n")
                    let prompt: String
                    if priorContext.isEmpty {
                        prompt = "Act as the \(agent.name) specialist. For '\(topic)', propose one actionable ApexAgent improvement, why it matters, and the next implementation step without using tools. Do not report readiness or ask for files."
                    } else {
                        prompt = "Act as the \(agent.name) specialist. Previous discussion:\n\(priorContext)\n\nFor '\(topic)', respond concisely with your specialist recommendation and concrete next step without using tools."
                    }

                    let agentType = AgentType(rawValue: agent.name) ?? .developer
                    let request = AgentRequest(
                        senderIdentity: .archetype(agentType),
                        prompt: prompt,
                        toolCallingMode: .disabled
                    )
                    let terminalState = await AgentRequestRouter.shared.route(
                        request,
                        history: [],
                        instructions: instructions,
                        orchestrator: orchestrator
                    )
                    let trimmed = terminalState.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    let finalTurnContent = trimmed.isEmpty ? "Completed with no output." : trimmed
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

            // Quorum and consensus calculations
            let totalExpected = validAgents.count * rounds
            let isFailedTurn: (MeetingTurn) -> Bool = { turn in
                let stmt = turn.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                return stmt.isEmpty
                    || stmt == "Completed with no output."
                    || stmt.hasPrefix("Participant response unavailable:")
                    || stmt.hasPrefix("Error:")
                    || stmt.hasPrefix("ERROR:")
                    || stmt.hasPrefix("⚠️ Turn failed")
            }
            let successfulTurns = debateHistory.filter { !isFailedTurn($0) }
            let failedTurns = debateHistory.filter { isFailedTurn($0) }
            let quorumMet = successfulTurns.count >= (validAgents.count / 2 + 1)
            let confidence = totalExpected > 0 ? Double(successfulTurns.count) / Double(totalExpected) : 0.0

            let consensusStatus = quorumMet
                ? "Consensus reached (Confidence: \(Int(confidence * 100))%)."
                : "Quorum not reached: \(failedTurns.count) participant response(s) failed or timed out."

            // Complete the streaming
            await MainActor.run {
                accumulatedText += "\n\n--- \n\(consensusStatus)"
                orchestrator.updateMessage(id: messageId, content: accumulatedText)
                orchestrator.updateMessage(id: messageId, isStreaming: false)
            }

            // Return debate summary report to the Supervisor
            var finalReport = "Debate Transcript (\(consensusStatus)):\n"
            for turn in debateHistory {
                finalReport += "- \(turn.agentName): \(turn.statement)\n"
            }

            let majorityView = successfulTurns.map { "\($0.agentName): \($0.statement.prefix(300))" }.joined(separator: "\n")
            let minorityDissent = failedTurns.isEmpty ? nil : "Failed/Unavailable participants: " + failedTurns.map { $0.agentName }.joined(separator: ", ")
            let consensus = ConsensusReport(
                consensusDecision: quorumMet
                    ? "Panel reached consensus on '\(arguments.topic)' after \(successfulTurns.count) valid statements across \(validAgents.count) participants."
                    : "Panel failed to reach quorum on '\(arguments.topic)' (\(failedTurns.count) failures).",
                majorityView: majorityView.isEmpty ? "No valid consensus statements produced." : majorityView,
                minorityDissent: minorityDissent,
                confidence: confidence
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

        _ = Transcript(entries: transcriptEntries) // retained for future session seeding

        let session = orchestrator.orchestrator.sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: String(instructions.prefix(1200)),
            allowedTools: [],
            toolCallingMode: .allowed,
            reasoningLevel: nil,
            maxResponseTokens: nil,
            history: nil,
            prompt: topic
        )
        
        session.prewarm()
        return session
    }
}
