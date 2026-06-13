import Foundation
import FoundationModels
import AppKit

// MARK: - Delegate Task Tool

struct DelegateTaskTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "delegate_task"
    let description = "Delegates a specific sub-task to a specialized sub-agent (developer, executor, controller, researcher) and returns their final response report."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The type of sub-agent to delegate the task to (developer, executor, controller, researcher)")
        var agentType: String

        @Guide(description: "The detailed task instructions and context for the sub-agent to execute.")
        var taskDescription: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orchestrator = await self.orchestrator.orchestrator
            
            if ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1" {
                return "Mock delegation response for agent \(arguments.agentType): \(arguments.taskDescription)"
            }
            
            guard let type = AgentType(rawValue: arguments.agentType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return "ERROR: Invalid agentType '\(arguments.agentType)'. Must be one of: developer, executor, controller, researcher, linter, uiDesigner, planner"
            }
            
            let indicatorPrefix = switch type {
            case .developer: "💻 [Codex]"
            case .executor: "⚙️ [Nexus]"
            case .controller: "🎮 [Pilot]"
            case .researcher: "🔍 [Oracle]"
            case .linter: "🧹 [Auditor]"
            case .uiDesigner: "🎨 [Aura]"
            case .planner: "📅 [Chronos]"
            }
            let startMessage = "\(indicatorPrefix) is starting task:\n> \(arguments.taskDescription)\n\n"
            
            // 1. Create the session and append the initial chat message on the MainActor
            let (session, messageId) = try await MainActor.run {
                let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                let msgId = chatMsg.id
                orchestrator.messages.append(chatMsg)
                
                let s = createSubAgentSession(
                    type: type,
                    preference: orchestrator.modelPreference,
                    instructions: type.systemPrompt
                )
                s.prewarm()
                return (s, msgId)
            }
            
            // 2. Stream the sub-agent response and update the UI asynchronously
            var finalContent = ""
            let stream = session.streamResponse(to: arguments.taskDescription)
            for try await response in stream {
                finalContent = response.content
                await MainActor.run {
                    if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                        orchestrator.messages[idx].content = startMessage + finalContent
                    }
                }
            }
            
            // 3. Mark the message as finished streaming on the MainActor
            await MainActor.run {
                if let idx = orchestrator.messages.firstIndex(where: { $0.id == messageId }) {
                    orchestrator.messages[idx].isStreaming = false
                }
            }
            
            return finalContent
        }
    }

    @MainActor
    private func createSubAgentSession(
        type: AgentType,
        preference: AgentModelPreference,
        instructions: String
    ) -> LanguageModelSession {
        let transcript = Transcript(entries: [])
        switch preference {
        case .localSystem:
            let model = SystemLanguageModel.default
            switch type {
            case .developer:
                return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                return LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                return LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                return LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                return LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                return LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                return LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            switch type {
            case .developer:
                return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                return LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                return LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                return LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                return LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                return LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                return LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            switch type {
            case .developer:
                return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                return LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                return LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                return LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                return LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                return LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                return LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            switch type {
            case .developer:
                return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .executor:
                return LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .controller:
                return LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .researcher:
                return LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .linter:
                return LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .uiDesigner:
                return LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            case .planner:
                return LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
            }
        case .hybrid:
            let usePCC = (type == .developer || type == .researcher)
            if usePCC {
                let model = PrivateCloudComputeLanguageModel()
                switch type {
                case .developer:
                    return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .researcher:
                    return LanguageModelSession(profile: ResearcherAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                default:
                    return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                }
            } else {
                let model = SystemLanguageModel.default
                switch type {
                case .executor:
                    return LanguageModelSession(profile: ExecutorAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .controller:
                    return LanguageModelSession(profile: ControllerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .linter:
                    return LanguageModelSession(profile: LinterAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .uiDesigner:
                    return LanguageModelSession(profile: UIDesignerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                case .planner:
                    return LanguageModelSession(profile: PlannerAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                default:
                    return LanguageModelSession(profile: DeveloperAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed), history: transcript)
                }
            }
        }
    }
}
