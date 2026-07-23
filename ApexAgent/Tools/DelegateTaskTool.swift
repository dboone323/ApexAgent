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
            
            let agentName = arguments.agentType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let agent = await AgentRegistry.shared.resolve(name: agentName) else {
                return "ERROR: Invalid agentType '\(arguments.agentType)'."
            }
            
            let indicatorPrefix: String
            switch agent.name.lowercased() {
            case "developer": indicatorPrefix = "💻 [Codex]"
            case "executor": indicatorPrefix = "⚙️ [Nexus]"
            case "controller": indicatorPrefix = "🎮 [Pilot]"
            case "researcher": indicatorPrefix = "🔍 [Oracle]"
            case "linter": indicatorPrefix = "🧹 [Auditor]"
            case "uidesigner": indicatorPrefix = "🎨 [Aura]"
            case "planner": indicatorPrefix = "📅 [Chronos]"
            default:
                let displayName = agent.name.prefix(1).uppercased() + agent.name.dropFirst()
                indicatorPrefix = "🤖 [\(displayName)]"
            }
            let startMessage = "\(indicatorPrefix) is starting task:\n> \(arguments.taskDescription)\n\n"
            
            // 1. Create the session and append the initial chat message on the MainActor
            let (session, messageId) = await MainActor.run {
                let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                let msgId = chatMsg.id
                orchestrator.appendMessage(chatMsg)
                
                let s = createSubAgentSession(
                    agent: agent,
                    preference: orchestrator.modelPreference,
                    instructions: agent.systemPrompt
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
                    orchestrator.updateMessage(id: messageId, content: startMessage + finalContent)
                }
            }
            
            // 3. Mark the message as finished streaming on the MainActor and log coordination trace
            await MainActor.run {
                orchestrator.updateMessage(id: messageId, isStreaming: false)
                let displayName = agent.name.prefix(1).uppercased() + agent.name.dropFirst()
                let trace = AgentTraceLog(
                    sourceAgent: "Supervisor",
                    targetAgent: displayName,
                    action: "delegate_task",
                    details: "Delegated sub-task: \(arguments.taskDescription.prefix(150))"
                )
                orchestrator.coordinationTraces.append(trace)
            }
            
            return finalContent
        }
    }

    @MainActor
    private func createSubAgentSession(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String
    ) -> LanguageModelSession {
        let transcript = Transcript(entries: [])
        
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
            return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .privateCloud:
            if AgentOrchestrator.isPrivateCloudComputeAvailable() {
                let model = PrivateCloudComputeLanguageModel()
                return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            } else {
                let model = SystemLanguageModel.default
                return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            }
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
        case .hybrid:
            let usePCC = (agent.name == "developer" || agent.name == "researcher")
            if usePCC && AgentOrchestrator.isPrivateCloudComputeAvailable() {
                let model = PrivateCloudComputeLanguageModel()
                return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            } else {
                let model = SystemLanguageModel.default
                return LanguageModelSession(profile: SpecializedAgentProfile(instructions: instructions, model: model, toolCallingMode: .allowed, orchestrator: orchestrator, allowedTools: agent.allowedTools), history: transcript)
            }
        }
    }
}
