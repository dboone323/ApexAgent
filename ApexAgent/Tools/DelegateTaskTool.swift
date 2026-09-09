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
    let description = "Delegates a specific sub-task to a specialized sub-agent (developer/Codex, executor/Nexus, controller/Pilot, researcher/Oracle, linter/Auditor, uiDesigner/Aura, planner/Chronos) and returns their final response report."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The type or name of sub-agent to delegate to (e.g. 'developer'/'Codex', 'executor'/'Nexus', 'controller'/'Pilot', 'researcher'/'Oracle')")
        var agentType: String

        @Guide(description: "The detailed task instructions and context for the sub-agent to execute.")
        var taskDescription: String
    }

    @TaskLocal static var activeDelegationDepth: Int = 0

    func call(arguments: Arguments) async throws -> String {
        print("[DELEGATION] delegate_task called with agent=\(arguments.agentType), task=\(arguments.taskDescription)")
        fflush(stdout)
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
                
                let orchPreference = await MainActor.run { orchestrator.modelPreference }
                let subAgentPreference: AgentModelPreference
                if let agentPrefStr = agent.modelPreference, let pref = AgentModelPreference(rawValue: agentPrefStr) {
                    subAgentPreference = pref
                } else {
                    subAgentPreference = orchPreference
                }

                let safeTools = agent.allowedTools.filter { $0 != "delegate_task" && $0 != "convene_meeting" }
                let estimatedTokens = ModelRegistry.estimateTokenCount(
                    prompt: arguments.taskDescription,
                    instructions: agent.systemPrompt,
                    tools: safeTools
                )

                let effectivePreference: AgentModelPreference
                if (subAgentPreference == .autoPicker || subAgentPreference == .localSystem) && estimatedTokens > 3200 {
                    effectivePreference = .localOllama
                    print("🧠 [DelegateTaskTool] Sub-agent '\(agent.name)' task is ~\(estimatedTokens) tokens (>3.2k safe limit). Pre-tiering to Local Ollama.")
                } else {
                    effectivePreference = subAgentPreference
                }

                // 1. Create the session and append the initial chat message on the MainActor
                let (session, messageId) = await MainActor.run {
                    let chatMsg = ChatMessage(role: .assistant, content: startMessage, isStreaming: true)
                    let msgId = chatMsg.id
                    orchestrator.appendMessage(chatMsg)
                    
                    let s = createSubAgentSession(
                        agent: agent,
                        preference: effectivePreference,
                        instructions: agent.systemPrompt,
                        prompt: arguments.taskDescription
                    )
                    return (s, msgId)
                }
                
                // 2. Generate the sub-agent response with auto-picker resilience.
                let subStartTime = Date()
                var finalContent = ""

                if effectivePreference == .localOllama {
                    print("[DELEGATION] 🚀 Sub-agent '\(agent.name)' executing via OllamaAgentEngine (gemma4:12b)...")
                    finalContent = try await executeViaOllama(
                        orchestrator: orchestrator,
                        agent: agent,
                        taskDescription: arguments.taskDescription,
                        safeTools: safeTools
                    )
                } else {
                    do {
                        let response = try await session.respond(
                            to: Prompt(arguments.taskDescription),
                            options: GenerationOptions(toolCallingMode: .allowed)
                        )
                        finalContent = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    } catch {
                        let errStr = "\(error)"
                        let isContextOrTokenLimit = errStr.contains("context")
                            || errStr.contains("tokenize")
                            || errStr.contains("4,096")
                            || errStr.contains("4096")
                            || errStr.contains("InferenceError")

                        if isContextOrTokenLimit {
                            print("⚠️ [DelegateTaskTool] Sub-agent '\(agent.name)' exceeded on-device token limit (\(errStr)). Auto-tiering fallback to Local Ollama (gemma4:12b)...")
                            finalContent = try await executeViaOllama(
                                orchestrator: orchestrator,
                                agent: agent,
                                taskDescription: arguments.taskDescription,
                                safeTools: safeTools
                            )
                        } else {
                            throw error
                        }
                    }
                }

                let elapsed = String(format: "%.2f", Date().timeIntervalSince(subStartTime))
                print("[DELEGATION] ✅ Sub-agent '\(agent.name)' finished in \(elapsed)s: '\(finalContent.prefix(80))'")
                fflush(stdout)

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

                let returnSummary = finalContent.count > 2500 ? String(finalContent.prefix(2500)) + "\n[... sub-agent report truncated ...]" : finalContent
                return returnSummary
            }
        }
    }

    @MainActor
    private func executeViaOllama(
        orchestrator: AgentOrchestrator,
        agent: RegisteredAgent,
        taskDescription: String,
        safeTools: [String]
    ) async throws -> String {
        let engine = OllamaAgentEngine(orchestrator: orchestrator, allowedTools: safeTools)
        var subOutput = ""
        try await engine.streamResponse(
            prompt: taskDescription,
            attachments: [],
            history: [],
            instructions: agent.systemPrompt,
            toolCallingMode: .auto,
            onUpdate: { partial in
                subOutput = partial
            }
        )
        return subOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func createSubAgentSession(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        prompt: String = ""
    ) -> LanguageModelSession {
        // Ensure subagents never inherit recursive delegation tools
        let safeTools = agent.allowedTools.filter { $0 != "delegate_task" && $0 != "convene_meeting" }
        return orchestrator.orchestrator.sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: instructions,
            allowedTools: safeTools,
            toolCallingMode: .allowed,
            reasoningLevel: apexConfiguredReasoningLevel(),
            maxResponseTokens: apexConfiguredMaxResponseTokens(),
            history: nil,
            prompt: prompt
        )
    }
}
