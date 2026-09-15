import Foundation
import FoundationModels

// MARK: - Dispatch Swarm Tool (Parallel Multi-Bot Execution)
//
// Allows orchestrators, chiefs of staff, and supervisor agents to dispatch multiple
// subtasks in parallel across distinct specialized bots and await a combined synthesis.

struct DispatchSwarmTool: Tool, @unchecked Sendable {
    let botManager: BotManager?

    init(botManager: BotManager?) {
        self.botManager = botManager
    }

    let name = "dispatch_swarm"
    let description = "Dispatches multiple tasks concurrently to different specialist bots in parallel, awaiting all responses and returning an aggregated summary."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Comma-separated list of target bot names, e.g. 'Codex, Nexus, Auditor, Oracle'")
        var targetBots: String

        @Guide(description: "Single string containing the task prompt or instructions for the swarm")
        var taskPrompts: String

        enum CodingKeys: String, CodingKey {
            case targetBots, bots, botNames, target
            case taskPrompts, taskPrompt, prompt, task, instructions
        }

        init(targetBots: String, taskPrompts: String) {
            self.targetBots = targetBots
            self.taskPrompts = taskPrompts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            if let botsList = (try? container.decode([String].self, forKey: .targetBots)) ?? (try? container.decode([String].self, forKey: .bots)) ?? (try? container.decode([String].self, forKey: .botNames)) {
                self.targetBots = botsList.joined(separator: ", ")
            } else if let botsStr = (try? container.decode(String.self, forKey: .targetBots)) ?? (try? container.decode(String.self, forKey: .bots)) ?? (try? container.decode(String.self, forKey: .botNames)) ?? (try? container.decode(String.self, forKey: .target)) {
                self.targetBots = botsStr
            } else {
                self.targetBots = ""
            }

            if let promptsList = (try? container.decode([String].self, forKey: .taskPrompts)) ?? (try? container.decode([String].self, forKey: .taskPrompt)) ?? (try? container.decode([String].self, forKey: .prompt)) {
                self.taskPrompts = promptsList.joined(separator: "\n")
            } else if let promptStr = (try? container.decode(String.self, forKey: .taskPrompts)) ?? (try? container.decode(String.self, forKey: .taskPrompt)) ?? (try? container.decode(String.self, forKey: .prompt)) ?? (try? container.decode(String.self, forKey: .task)) ?? (try? container.decode(String.self, forKey: .instructions)) {
                self.taskPrompts = promptStr
            } else {
                self.taskPrompts = ""
            }
        }
    }

    struct SwarmResult: Sendable {
        let botName: String
        let output: String
        let success: Bool
    }

    func call(arguments: Arguments) async throws -> String {
        guard let botManager else {
            return "ERROR: BotManager is unavailable."
        }

        let botNames = arguments.targetBots
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Split task prompts:
        // Check for explicit delimiters (|||, \n---\n, \n===\n, or pipe |)
        let prompts: [String]
        let rawPrompts = arguments.taskPrompts.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPrompts.contains("|||") {
            prompts = rawPrompts.components(separatedBy: "|||")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if rawPrompts.contains("\n---\n") {
            prompts = rawPrompts.components(separatedBy: "\n---\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if rawPrompts.contains("\n===\n") {
            prompts = rawPrompts.components(separatedBy: "\n===\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if rawPrompts.contains("|") && !rawPrompts.contains("\n") {
            prompts = rawPrompts.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            // If single prompt or multi-line markdown prompt without explicit delimiters,
            // provide the full prompt to each bot rather than breaking markdown lines.
            prompts = [rawPrompts]
        }

        guard !botNames.isEmpty else {
            return "ERROR: No target bots provided."
        }

        guard !prompts.isEmpty else {
            return "ERROR: No task prompts provided."
        }

        // Pair bots with prompts (repeat last prompt if counts mismatch)
        var assignments: [(String, String)] = []
        for (idx, name) in botNames.enumerated() {
            let basePrompt = idx < prompts.count ? prompts[idx] : (prompts.last ?? "")
            let botPrompt = """
            [INSTRUCTION FOR \(name.uppercased())]:
            You are \(name). Act immediately on the task prompt below using your available tools. Perform real analysis, inspect files, check configurations, and return your concrete findings and audit results. Do NOT merely acknowledge readiness or state what you plan to do; execute your tools and deliver the completed report.

            \(basePrompt)
            """
            assignments.append((name, botPrompt))
        }

        // Bounded parallel execution across swarm bots (max 4 concurrent workers)
        let maxConcurrency = 4
        var results: [SwarmResult] = []

        try await withThrowingTaskGroup(of: SwarmResult.self) { group in
            var submitted = 0
            for (botName, taskPrompt) in assignments {
                if submitted >= maxConcurrency {
                    if let res = try await group.next() {
                        results.append(res)
                    }
                }
                submitted += 1
                group.addTask {
                    let sanitizedPrompt = SecretRedactor.redact(text: taskPrompt)
                    let output: String = await Task { @MainActor in
                        if let bot = botManager.botByName(botName) ?? (UUID(uuidString: botName).flatMap { botManager.bot(byId: $0) }) {
                            let session = botManager.session(for: bot)
                            let response = await session.sendMessageAsync(sanitizedPrompt)
                            let rawOut = response ?? "Completed with no output."
                            return SecretRedactor.redact(text: rawOut)
                        } else if let agent = AgentRegistry.shared.resolve(name: botName) {
                            if let orchestrator = botManager.orchestrator {
                                let safeTools = agent.allowedTools.filter {
                                    $0 != "delegate_task" && $0 != "convene_meeting" && $0 != "dispatch_swarm"
                                }
                                let engine = OllamaAgentEngine(orchestrator: orchestrator, allowedTools: safeTools)
                                var subOutput = ""
                                do {
                                    try await engine.streamResponse(
                                        prompt: sanitizedPrompt,
                                        attachments: [],
                                        history: [],
                                        instructions: agent.systemPrompt,
                                        toolCallingMode: .auto,
                                        onUpdate: { partial in
                                            subOutput = partial
                                        }
                                    )
                                } catch {
                                    subOutput = "ERROR: Agent execution failed: \(error.localizedDescription)"
                                }
                                let raw = subOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                                return raw.isEmpty ? "Completed with no output." : SecretRedactor.redact(text: raw)
                            }
                            return "ERROR: Orchestrator unavailable for agent '\(botName)'."
                        } else {
                            return "ERROR: Bot '\(botName)' not found."
                        }
                    }.value

                    return SwarmResult(botName: botName, output: output, success: !output.hasPrefix("ERROR:"))
                }
            }
            while let res = try await group.next() {
                results.append(res)
            }
        }

        var report = "🐝 Swarm Parallel Execution Complete (\(results.count) bots):\n\n"
        for res in results.sorted(by: { $0.botName < $1.botName }) {
            let icon = res.success ? "✅" : "⚠️"
            report += "### \(icon) [\(res.botName)]\n\(res.output)\n\n"
        }
        return report
    }
}
