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
            guard let agent = AgentRegistry.shared.resolve(name: agentName) else {
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
                s.prewarm(promptPrefix: Prompt("Execute the following task"))
                return (s, msgId)
            }
            
            // 2. Generate the sub-agent response.
            let response = try await session.respond(
                to: Prompt(arguments.taskDescription),
                options: GenerationOptions(toolCallingMode: .allowed)
            )
            let finalContent = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            // 3. Update the assistant bubble on the MainActor.
            await MainActor.run {
                orchestrator.updateMessage(id: messageId, content: startMessage + finalContent)
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

            // WS1.5 reconciliation: record the structured handoff result so the
            // orchestrator / dashboard can reconcile sub-agent work without
            // re-parsing the free-text response. Non-breaking — the String
            // return below is unchanged.
            let handoff = TaskResult(
                taskId: UUID().uuidString,
                status: finalContent.isEmpty ? "failed" : "completed",
                resultSummary: finalContent.prefix(2000).description,
                errorDetails: finalContent.isEmpty ? "Sub-agent returned no content" : nil
            )
            await AgentRegistry.shared.recordHandoff(handoff)

            return finalContent
        }
    }

    @MainActor
    private func createSubAgentSession(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String
    ) -> LanguageModelSession {
        return orchestrator.orchestrator.sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: instructions,
            allowedTools: agent.allowedTools,
            toolCallingMode: .allowed,
            reasoningLevel: apexConfiguredReasoningLevel(),
            maxResponseTokens: apexConfiguredMaxResponseTokens()
        )
    }
}
