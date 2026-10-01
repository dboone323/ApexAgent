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

        @Guide(description: "Single string or |||-delimited / JSON array of task prompts for the swarm")
        var taskPrompts: String

        enum CodingKeys: String, CodingKey {
            case targetBots, bots, botNames, target
            case taskPrompts, taskPrompt, prompt, task, tasks, instructions
        }

        struct TaskItem: Decodable {
            let agent: String?
            let bot: String?
            let prompt: String?
            let task: String?

            var resolvedAgent: String? { agent ?? bot }
            var resolvedPrompt: String? { prompt ?? task }
        }

        init(targetBots: String, taskPrompts: String) {
            self.targetBots = targetBots
            self.taskPrompts = taskPrompts
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            var parsedBots: [String] = []
            var parsedPrompts: [String] = []

            let taskKeys: [CodingKeys] = [.tasks, .taskPrompts]
            for key in taskKeys where parsedPrompts.isEmpty {
                if let items = try? container.decode([TaskItem].self, forKey: key) {
                    for item in items {
                        if let a = item.resolvedAgent, !a.isEmpty {
                            parsedBots.append(a)
                        }
                        if let p = item.resolvedPrompt, !p.isEmpty {
                            parsedPrompts.append(p)
                        }
                    }
                }
            }

            let botKeys: [CodingKeys] = [.targetBots, .bots, .botNames, .target]
            var resolvedTargetBots = ""
            for key in botKeys where resolvedTargetBots.isEmpty {
                if let list = try? container.decode([String].self, forKey: key), !list.isEmpty {
                    resolvedTargetBots = list.joined(separator: ", ")
                } else if let str = try? container.decode(String.self, forKey: key), !str.isEmpty {
                    resolvedTargetBots = str
                }
            }
            if resolvedTargetBots.isEmpty && !parsedBots.isEmpty {
                resolvedTargetBots = parsedBots.joined(separator: ", ")
            }
            self.targetBots = resolvedTargetBots

            let promptKeys: [CodingKeys] = [.taskPrompts, .taskPrompt, .prompt, .task, .tasks, .instructions]
            var resolvedTaskPrompts = ""
            if !parsedPrompts.isEmpty {
                resolvedTaskPrompts = parsedPrompts.joined(separator: " ||| ")
            } else {
                for key in promptKeys where resolvedTaskPrompts.isEmpty {
                    if let list = try? container.decode([String].self, forKey: key), !list.isEmpty {
                        resolvedTaskPrompts = list.joined(separator: " ||| ")
                    } else if let str = try? container.decode(String.self, forKey: key), !str.isEmpty {
                        resolvedTaskPrompts = str
                    }
                }
            }
            self.taskPrompts = resolvedTaskPrompts
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

        let argsString = "targetBots: \(arguments.targetBots), taskPrompts: \(arguments.taskPrompts)"
        await MainActor.run {
            botManager.orchestrator?.logToolStart(name: self.name, arguments: argsString)
            botManager.orchestrator?.updateToolStatus(name: self.name, status: .running)
        }

        var botNames = arguments.targetBots
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Split task prompts:
        // 1. Check if rawPrompts is a JSON array (either [{"agent":"...","prompt":"..."}] or ["prompt1","prompt2"])
        // 2. Otherwise check for explicit delimiters (|||, \n---\n, \n===\n, or pipe |)
        var prompts: [String] = []
        let rawPrompts = arguments.taskPrompts.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPrompts.hasPrefix("["), let jsonData = rawPrompts.data(using: .utf8) {
            if let dictArray = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] {
                var jsonBots: [String] = []
                for item in dictArray {
                    if let p = (item["prompt"] as? String) ?? (item["task"] as? String) ?? (item["instructions"] as? String) {
                        prompts.append(p.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    if let a = (item["agent"] as? String) ?? (item["bot"] as? String) {
                        jsonBots.append(a.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                if botNames.isEmpty && !jsonBots.isEmpty {
                    botNames = jsonBots
                }
            } else if let strArray = try? JSONSerialization.jsonObject(with: jsonData) as? [String] {
                prompts = strArray.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        }

        if prompts.isEmpty {
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
            } else if !rawPrompts.isEmpty {
                // If single prompt or multi-line markdown prompt without explicit delimiters,
                // provide the full prompt to each bot rather than breaking markdown lines.
                prompts = [rawPrompts]
            }
        }

        guard !botNames.isEmpty else {
            let err = "ERROR: No target bots provided."
            await MainActor.run {
                botManager.orchestrator?.logToolEnd(name: self.name, result: err, status: .failed(err))
            }
            return err
        }

        guard !prompts.isEmpty else {
            let err = "ERROR: No task prompts provided."
            await MainActor.run {
                botManager.orchestrator?.logToolEnd(name: self.name, result: err, status: .failed(err))
            }
            return err
        }

        // Pair bots with prompts (repeat last prompt if counts mismatch)
        var assignments: [(String, String, Bool)] = []
        for (idx, name) in botNames.enumerated() {
            let basePrompt = idx < prompts.count ? prompts[idx] : (prompts.last ?? "")
            let needsTools = IntentToolSelector.shouldEnableTools(for: basePrompt)
            let botPrompt: String
            if needsTools {
                botPrompt = """
                [INSTRUCTION FOR \(name.uppercased())]:
                You are \(name). Act immediately on the task prompt below using your available tools. Perform real analysis, inspect files, check configurations, and return your concrete findings and audit results. Do NOT merely acknowledge readiness or state what you plan to do; execute your tools and deliver the completed report.

                \(basePrompt)
                """
            } else {
                botPrompt = """
                [INSTRUCTION FOR \(name.uppercased())]:
                You are \(name). Answer the task prompt below directly and concisely from your domain expertise without calling any tools.

                \(basePrompt)
                """
            }
            assignments.append((name, botPrompt, needsTools))
        }

        // Bounded parallel execution across swarm bots (max 4 concurrent workers)
        let maxConcurrency = 4
        var results: [SwarmResult] = []

        try await withThrowingTaskGroup(of: SwarmResult.self) { group in
            var submitted = 0
            for (botName, taskPrompt, needsTools) in assignments {
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
                                let mode: AgentToolCallingMode = needsTools ? .auto : .disabled
                                let agentType = AgentType(rawValue: agent.name) ?? .developer
                                let request = AgentRequest(
                                    senderIdentity: .archetype(agentType),
                                    prompt: sanitizedPrompt,
                                    toolCallingMode: mode
                                )
                                let terminalState = await AgentRequestRouter.shared.route(
                                    request,
                                    history: [],
                                    instructions: agent.systemPrompt,
                                    orchestrator: orchestrator
                                )
                                let raw = terminalState.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
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

        await MainActor.run {
            botManager.orchestrator?.logToolEnd(name: self.name, result: report, status: .success)
        }
        return report
    }
}
