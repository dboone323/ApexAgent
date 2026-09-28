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
    let description = "Delegates the user's specific concrete task to a specialized sub-agent (developer/Codex, executor/Nexus, controller/Pilot, researcher/Oracle, linter/Auditor, uiDesigner/Aura, planner/Chronos) and returns the completed response report. Preserve the task; do not replace it with a generic operational-status or readiness report unless the user explicitly requested readiness."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The type or name of sub-agent to delegate to (e.g. 'developer'/'Codex', 'executor'/'Nexus', 'controller'/'Pilot', 'researcher'/'Oracle')")
        var agentType: String

        @Guide(description: "The detailed task instructions and context for the sub-agent to execute.")
        var taskDescription: String
    }

    @TaskLocal static var activeDelegationDepth: Int = 0

    func call(arguments: Arguments) async throws -> String {
        guard Self.activeDelegationDepth < 2 else {
            return "ERROR: Maximum delegation depth reached. Please execute your specialized sub-task directly using your tools without delegating further."
        }
        return try await Self.$activeDelegationDepth.withValue(Self.activeDelegationDepth + 1) {
            try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
                let orchestrator = await self.orchestrator.orchestrator
                
                let agentName = arguments.agentType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard let agent = AgentRegistry.shared.resolve(name: agentName) else {
                    return "ERROR: Invalid agentType '\(arguments.agentType)'."
                }

                let (allowed, limitMessage) = await MainActor.run {
                    orchestrator.recordDelegation(to: agent.name)
                }
                if !allowed, let limitMessage = limitMessage {
                    return limitMessage
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
                
                // 1. Create the initial placeholder chat message on MainActor
                let messageId = await MainActor.run {
                    let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                    orchestrator.appendMessage(chatMsg)
                    return chatMsg.id
                }

                // 2. Generate the sub-agent response with AgentRequestRouter resilience & fallback
                let subStartTime = Date()
                let agentType = AgentType(rawValue: agent.name) ?? .developer
                let request = AgentRequest(
                    senderIdentity: .archetype(agentType),
                    prompt: arguments.taskDescription,
                    toolCallingMode: .auto
                )

                let terminalState = await AgentRequestRouter.shared.route(
                    request,
                    history: [],
                    instructions: agent.systemPrompt,
                    orchestrator: orchestrator,
                    onUpdate: { partial in
                        Task { @MainActor in
                            orchestrator.updateMessage(id: messageId, content: startMessage + partial)
                        }
                    }
                )

                let finalContent = terminalState.userFacingMessage

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

                // 4. Record subagent turn and handoff
                let handoff = TaskResult(
                    taskId: UUID().uuidString,
                    status: finalContent.isEmpty ? "failed" : "completed",
                    resultSummary: finalContent.prefix(2000).description
                )
                await AgentRegistry.shared.recordHandoff(handoff)

                let returnSummary = finalContent.count > 2500 ? String(finalContent.prefix(2500)) + "\n[... sub-agent report truncated ...]" : finalContent
                return returnSummary
            }
        }
    }
}
