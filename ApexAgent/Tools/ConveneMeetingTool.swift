import Foundation
import FoundationModels
import AppKit

// MARK: - Convene Meeting Tool

struct ConveneMeetingTool: Tool {
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
        return try await executeWithLogging(arguments: arguments) {
            guard let orchestrator = await AgentOrchestrator.shared else {
                return "ERROR: AgentOrchestrator is not available"
            }

            if await AgentOrchestrator.isCLITestMode {
                return "Debate Consensus Transcript:\n- Developer: Discussed topic \(arguments.topic) and agreed on a plan.\n- Planner: Agreed to prioritize concurrency fixes."
            }

            // Parse participants
            var validTypes: [AgentType] = []
            for p in arguments.participants {
                let cleaned = p.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if let type = AgentType(rawValue: cleaned) {
                    validTypes.append(type)
                }
            }

            if validTypes.isEmpty {
                return "ERROR: No valid participants provided. Must be subset of: developer, executor, controller, researcher, linter, uiDesigner, planner"
            }

            // Add meeting discussion message in the chat
            let startMessage = "👥 [Multi-Agent Panel Meeting]\nTopic: *\(arguments.topic)*\nParticipants: \(validTypes.map { $0.rawValue.capitalized }.joined(separator: ", "))\n\n---"
            
            let messageId = await MainActor.run {
                let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                orchestrator.messages.append(chatMsg)
                return chatMsg.id
            }

            var debateHistory: [MeetingTurn] = []
            var accumulatedText = startMessage

            // Run up to 2 rounds of discussion
            for round in 1...2 {
                await MainActor.run {
                    accumulatedText += "\n\n**Round \(round) Discussion:**"
                    if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                        orchestrator.messages[idx].content = accumulatedText
                    }
                }

                for type in validTypes {
                    let agentName = type.displayName
                    let turnHeader = "\n\n🤖 [\(agentName)] is thinking..."
                    
                    await MainActor.run {
                        if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                            orchestrator.messages[idx].content = accumulatedText + turnHeader
                        }
                    }

                    // Hydrate session with the conversation history so far
                    let instructions = type.systemPrompt
                    let preference = await orchestrator.modelPreference
                    let session = await createVisualSession(
                        type: type,
                        preference: preference,
                        instructions: instructions,
                        topic: arguments.topic,
                        debateHistory: debateHistory
                    )

                    var finalTurnContent = ""
                    let prompt = "Please provide your contribution and response/feedback to the discussion on: \(arguments.topic)"
                    let stream = session.streamResponse(to: prompt)
                    
                    for try await response in stream {
                        finalTurnContent = response.content
                        await MainActor.run {
                            if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                                orchestrator.messages[idx].content = accumulatedText + "\n\n🤖 [\(agentName)]: \(finalTurnContent)"
                            }
                        }
                    }

                    debateHistory.append(MeetingTurn(agentName: agentName, statement: finalTurnContent))
                    accumulatedText += "\n\n🤖 [\(agentName)]: \(finalTurnContent)"
                }
            }

            // Complete the streaming
            await MainActor.run {
                accumulatedText += "\n\n--- \nConsensus reached."
                if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                    orchestrator.messages[idx].content = accumulatedText
                    orchestrator.messages[idx].isStreaming = false
                }
            }

            // Return debate summary report to Supervisor
            var finalReport = "Debate Consensus Transcript:\n"
            for turn in debateHistory {
                finalReport += "- \(turn.agentName): \(turn.statement)\n"
            }
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
        type: AgentType,
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
        switch preference {
        case .localSystem:
            let model = SystemLanguageModel.default
            switch type {
            case .developer:
                session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                session = LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                session = LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                session = LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                session = LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                session = LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                session = LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            switch type {
            case .developer:
                session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                session = LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                session = LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                session = LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                session = LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                session = LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                session = LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            switch type {
            case .developer:
                session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                session = LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                session = LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                session = LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                session = LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                session = LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                session = LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            switch type {
            case .developer:
                session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                session = LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                session = LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                session = LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                session = LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                session = LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                session = LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .hybrid:
            let usePCC = (type == .developer || type == .researcher)
            if usePCC {
                let model = PrivateCloudComputeLanguageModel()
                switch type {
                case .developer:
                    session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .researcher:
                    session = LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                default:
                    session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                }
            } else {
                let model = SystemLanguageModel.default
                switch type {
                case .executor:
                    session = LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .controller:
                    session = LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .linter:
                    session = LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .uiDesigner:
                    session = LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .planner:
                    session = LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                default:
                    session = LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                }
            }
        }
        
        session.prewarm()
        return session
    }
}
