import Foundation
import SwiftUI
import AppKit

// MARK: - Builtin Slash Command Names

public enum BuiltinSlashCommandName: String, CaseIterable, Identifiable, Sendable {
    case plan = "plan"
    case help = "help"
    case clear = "clear"
    case compact = "compact"
    case routines = "routines"
    case playbook = "playbook"
    case diagnostics = "diagnostics"
    case memory = "memory"
    case audit = "audit"
    case model = "model"

    public var id: String { rawValue }

    public var commandPrefix: String { "/\(rawValue)" }

    public var title: String {
        switch self {
        case .plan: return "Execution Plan"
        case .help: return "Help & Guide"
        case .clear: return "Clear Conversation"
        case .compact: return "Compact Context"
        case .routines: return "Routines & Automation"
        case .playbook: return "Run Playbook"
        case .diagnostics: return "System Diagnostics"
        case .memory: return "Cognitive Memory"
        case .audit: return "Project & Security Audit"
        case .model: return "Model Provider"
        }
    }

    public var summary: String {
        switch self {
        case .plan:
            return "Create, visualize, or execute a multi-step task plan (/plan <goal>)"
        case .help:
            return "Show all slash commands, @bot mentions, keyboard shortcuts, and capabilities"
        case .clear:
            return "Clear all messages from the current conversation"
        case .compact:
            return "Compact older conversation turns into a synthesized digest to preserve context tokens"
        case .routines:
            return "List all configured automated routines, schedules, and active triggers"
        case .playbook:
            return "Execute a multi-agent collaboration playbook preset (/playbook <preset>)"
        case .diagnostics:
            return "Run full system diagnostic checks (CLT, Python, Node, Git, Entitlements, Tools)"
        case .memory:
            return "Search semantic facts and episodic memories stored across bots (/memory <query>)"
        case .audit:
            return "Audit the current workspace codebase for issues, TODOs, and security health"
        case .model:
            return "Switch model provider (/model <auto | gemini | ollama | mlx | afm | pcc>)"
        }
    }

    public var usage: String {
        switch self {
        case .plan: return "/plan <goal or task breakdown>"
        case .help: return "/help"
        case .clear: return "/clear"
        case .compact: return "/compact"
        case .routines: return "/routines [run <name> | list]"
        case .playbook: return "/playbook <pr_review | issue_to_patch | standup | list>"
        case .diagnostics: return "/diagnostics"
        case .memory: return "/memory <query>"
        case .audit: return "/audit"
        case .model: return "/model <auto | gemini | ollama | mlx | afm | pcc>"
        }
    }

    public var icon: String {
        switch self {
        case .plan: return "list.bullet.indent"
        case .help: return "questionmark.circle.fill"
        case .clear: return "trash"
        case .compact: return "arrow.triangle.merge"
        case .routines: return "clock.arrow.circlepath"
        case .playbook: return "play.circle.fill"
        case .diagnostics: return "checklist"
        case .memory: return "brain.head.profile"
        case .audit: return "shield.lefthalf.filled"
        case .model: return "cpu"
        }
    }
}

// MARK: - Slash Command Execution Result

public struct SlashCommandResult: Sendable {
    public let command: BuiltinSlashCommandName
    public let outputMarkdown: String
    public let shouldClearInput: Bool
    public let triggeredAgentExecution: Bool

    public init(
        command: BuiltinSlashCommandName,
        outputMarkdown: String,
        shouldClearInput: Bool = true,
        triggeredAgentExecution: Bool = false
    ) {
        self.command = command
        self.outputMarkdown = outputMarkdown
        self.shouldClearInput = shouldClearInput
        self.triggeredAgentExecution = triggeredAgentExecution
    }
}

// MARK: - Slash Command Engine

@MainActor
public final class BuiltinSlashCommandEngine {
    public static let shared = BuiltinSlashCommandEngine()

    private init() {}

    /// Checks if a given text input starts with a slash command prefix
    public static func isSlashCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("/")
    }

    /// Parses command name and optional argument
    public static func parse(_ text: String) -> (command: BuiltinSlashCommandName?, rawCommand: String, argument: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }

        let withoutSlash = String(trimmed.dropFirst())
        let parts = withoutSlash.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return nil }

        let rawCmd = String(first).lowercased()
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let matched = BuiltinSlashCommandName(rawValue: rawCmd)
        return (matched, rawCmd, argument)
    }

    /// Executes the slash command against the orchestrator and surrounding environment
    func execute(
        input: String,
        orchestrator: AgentOrchestrator,
        botManager: BotManager? = nil,
        spaceManager: SpaceManager? = nil
    ) async -> SlashCommandResult? {
        guard let parsed = Self.parse(input) else { return nil }

        guard let command = parsed.command else {
            let unknown = parsed.rawCommand
            let helpMsg = """
            ⚠️ **Unknown slash command:** `/\(unknown)`

            Available commands:
            \(BuiltinSlashCommandName.allCases.map { "• `/\($0.rawValue)` — \($0.summary)" }.joined(separator: "\n"))

            Type `/help` for detailed instructions and shortcuts.
            """
            return SlashCommandResult(command: .help, outputMarkdown: helpMsg)
        }

        let arg = parsed.argument

        switch command {
        case .plan:
            return await handlePlanCommand(arg: arg, orchestrator: orchestrator, botManager: botManager)

        case .help:
            return handleHelpCommand()

        case .clear:
            return handleClearCommand(orchestrator: orchestrator, botManager: botManager)

        case .compact:
            return await handleCompactCommand(orchestrator: orchestrator)

        case .routines:
            return await handleRoutinesCommand(arg: arg)

        case .playbook:
            return await handlePlaybookCommand(arg: arg, botManager: botManager)

        case .diagnostics:
            return await handleDiagnosticsCommand(orchestrator: orchestrator)

        case .memory:
            return await handleMemoryCommand(arg: arg, botManager: botManager)

        case .audit:
            return await handleAuditCommand()

        case .model:
            return handleModelCommand(arg: arg, orchestrator: orchestrator)
        }
    }

    // MARK: - Command Handlers

    private func handlePlanCommand(
        arg: String,
        orchestrator: AgentOrchestrator,
        botManager: BotManager?
    ) async -> SlashCommandResult {
        // Automatically open the Plan Dashboard
        UserDefaults.standard.set(true, forKey: "apex.showPlanDashboard")

        if arg.isEmpty {
            let currentSteps = orchestrator.activePlan
            if currentSteps.isEmpty {
                return SlashCommandResult(
                    command: .plan,
                    outputMarkdown: """
                    📋 **Plan Dashboard Activated**

                    No execution plan is currently active. To create and execute a structured plan, provide a goal:
                    ` /plan <your task or project goal>`

                    *Example:* `/plan Refactor network error handling and verify unit tests`
                    """
                )
            } else {
                let stepList = currentSteps.enumerated().map { idx, step in
                    let icon = step.status == .completed ? "✅" : (step.status == .running ? "⏳" : (step.status == .failed ? "❌" : "◻️"))
                    return "\(idx + 1). \(icon) **\(step.title)** [\(step.status.rawValue.capitalized)]"
                }.joined(separator: "\n")

                return SlashCommandResult(
                    command: .plan,
                    outputMarkdown: """
                    📋 **Current Execution Plan (\(currentSteps.count) steps)**

                    \(stepList)

                    *Open the sidebar Plan Dashboard to view real-time execution steps.*
                    """
                )
            }
        }

        // Initialize structured multi-step plan
        let initialSteps: [PlanStep] = [
            PlanStep(title: "Task Analysis & Workspace Assessment: \(arg)", status: .running),
            PlanStep(title: "Architecture & Implementation Strategy", status: .queued),
            PlanStep(title: "Code Execution & Mutation Verification", status: .queued),
            PlanStep(title: "Validation, Testing & Final Report", status: .queued)
        ]
        orchestrator.updatePlan(steps: initialSteps)

        let introMsg = """
        🎯 **Plan Initialized for Goal:** \(arg)

        1. ⏳ **Task Analysis & Workspace Assessment** (Running)
        2. ◻️ **Architecture & Implementation Strategy** (Queued)
        3. ◻️ **Code Execution & Mutation Verification** (Queued)
        4. ◻️ **Validation, Testing & Final Report** (Queued)

        *Plan execution started in the Plan Dashboard.*
        """

        // Post system announcement and trigger agent execution
        orchestrator.appendMessage(ChatMessage(role: .assistant, content: introMsg))
        orchestrator.sendMessage(
            "Execute the following task following the structured plan: \(arg). Update plan steps via update_plan tool as progress is made."
        )

        return SlashCommandResult(
            command: .plan,
            outputMarkdown: introMsg,
            triggeredAgentExecution: true
        )
    }

    private func handleHelpCommand() -> SlashCommandResult {
        let commandLines = BuiltinSlashCommandName.allCases.map { cmd in
            "| `/\(cmd.rawValue)` | `\(cmd.usage)` | \(cmd.summary) |"
        }.joined(separator: "\n")

        let helpMarkdown = """
        ## ⚡️ ApexAgent Quick Reference & Slash Commands

        | Command | Usage | Description |
        | :--- | :--- | :--- |
        \(commandLines)

        ---

        ### 🤖 Multi-Agent Mentions (@bot)
        - `@Apex` — Default AI Assistant
        - `@DevOpsBot` — Infrastructure, Docker, CLI & CI/CD
        - `@CoderBot` / `@Code-Architect` — Swift, System, & Code Implementations
        - `@ResearcherBot` — Web Search, Documentation & Retrieval
        - `@ChiefOfStaff` — Coordination, Planning & Task Delegation
        - `@all` / `@everyone` — In Spaces, broadcast prompt to all space bots

        ### ⌨️ Global Shortcuts
        - `⌥Space` — Open Global Command Palette
        - `⌘N` — New Clean Conversation
        - `⌘,` — App Settings & Permissions
        - `⇧Return` — Insert newline without sending
        - `Return` — Submit prompt / Queue if generating
        """

        return SlashCommandResult(command: .help, outputMarkdown: helpMarkdown)
    }

    private func handleClearCommand(
        orchestrator: AgentOrchestrator,
        botManager: BotManager?
    ) -> SlashCommandResult {
        orchestrator.startNewConversation()
        botManager?.activeSession?.clearMessages()

        return SlashCommandResult(
            command: .clear,
            outputMarkdown: "🧹 **Conversation cleared.** Starting a fresh session."
        )
    }

    private func handleCompactCommand(orchestrator: AgentOrchestrator) async -> SlashCommandResult {
        let messages = orchestrator.messages
        guard messages.count > 2 else {
            return SlashCommandResult(
                command: .compact,
                outputMarkdown: "ℹ️ Conversation has fewer than 3 turns. Context is already minimal."
            )
        }

        let formatted: [(role: String, content: String)] = messages.map { msg in
            let roleStr = switch msg.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            }
            return (role: roleStr, content: msg.content)
        }

        let input = CompactionInput(
            messages: formatted,
            maxTokenBudget: 2048,
            pinnedSystemPrompt: orchestrator.agentInstructions,
            recentTurnsToPreserve: 2
        )

        let result = await ContextCompactor.shared.compact(input)

        var newChatMessages: [ChatMessage] = []
        if !result.summary.isEmpty {
            newChatMessages.append(ChatMessage(
                role: .system,
                content: "📝 **Context Summary of \(result.summarizedTurnCount) previous turns:**\n\n\(result.summary)"
            ))
        }

        // Keep last 4 messages verbatim
        let recentCount = min(4, messages.count)
        let recentSlice = messages.suffix(recentCount)
        newChatMessages.append(contentsOf: recentSlice)

        orchestrator.replaceMessages(newChatMessages)

        return SlashCommandResult(
            command: .compact,
            outputMarkdown: "⚡️ **Context Compacted:** Summarized \(result.summarizedTurnCount) older turns. Estimated ~\(result.approximateTokensSaved) tokens saved."
        )
    }

    private func handleRoutinesCommand(arg: String) async -> SlashCommandResult {
        let routines = RoutineManager.shared.routines
        if routines.isEmpty {
            return SlashCommandResult(
                command: .routines,
                outputMarkdown: """
                ⏰ **No Automated Routines Configured**

                You can create scheduled or event-driven routines in **Settings ➔ Routines** or by teaching a bot.
                Supported triggers: Time Interval, Cron Schedule, Folder Monitor, Webhook, and Launch Agent.
                """
            )
        }

        let lines = routines.map { r in
            let status = r.enabled ? "🟢 Enabled" : "⚪️ Disabled"
            let triggerInfo = r.effectiveScheduleDescription
            return "• **\(r.name)** (\(status)) — \(triggerInfo)\n  *\(r.descriptionText.isEmpty ? "No description" : r.descriptionText)*"
        }.joined(separator: "\n\n")

        return SlashCommandResult(
            command: .routines,
            outputMarkdown: """
            ⏰ **Configured Routines (\(routines.count)):**

            \(lines)
            """
        )
    }

    private func handlePlaybookCommand(
        arg: String,
        botManager: BotManager?
    ) async -> SlashCommandResult {
        guard let bm = botManager else {
            return SlashCommandResult(
                command: .playbook,
                outputMarkdown: "❌ BotManager unavailable to execute playbook."
            )
        }

        let presets = CollaborationPlaybook.builtInPresets
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.isEmpty || trimmed == "list" {
            let list = presets.map { p in
                let presetId = p.presetKind?.rawValue ?? p.id.uuidString.lowercased()
                return "• `\(presetId)` — **\(p.name)** (\(p.stages.count) stages, requires approval: \(p.stages.contains { $0.requiresApproval } ? "Yes" : "No"))\n  \(p.description)"
            }.joined(separator: "\n\n")

            return SlashCommandResult(
                command: .playbook,
                outputMarkdown: """
                🎭 **Collaboration Playbooks**

                To run a playbook, type:
                `/playbook <preset_id>`

                **Available Presets:**
                \(list)
                """
            )
        }

        guard let selected = presets.first(where: {
            let pid = $0.presetKind?.rawValue ?? $0.id.uuidString.lowercased()
            return pid == trimmed || $0.id.uuidString.lowercased() == trimmed || $0.name.lowercased().contains(trimmed)
        }) else {
            return SlashCommandResult(
                command: .playbook,
                outputMarkdown: "⚠️ Unknown playbook preset `\(arg)`. Type `/playbook list` to view available presets."
            )
        }

        let runner = PlaybookRunner(playbook: selected, availableBots: bm.allBots, botManager: bm)
        bm.activePlaybookRunner = runner

        Task {
            _ = try? await runner.execute(contextInput: "Starting \(selected.name) run")
        }

        let assignedRoles = selected.stages.flatMap { $0.requiredRoles }.map { "@\($0.title)" }
        let assignedRolesSummary = Array(Set(assignedRoles)).joined(separator: ", ")

        return SlashCommandResult(
            command: .playbook,
            outputMarkdown: """
            🚀 **Executing Collaboration Playbook: \(selected.name)**

            • **Stages (\(selected.stages.count)):** \(selected.stages.map { $0.name }.joined(separator: " ➔ "))
            • **Assigned Bots:** \(assignedRolesSummary)

            *Progress and approval cards will appear in the active session.*
            """,
            triggeredAgentExecution: true
        )
    }

    private func handleDiagnosticsCommand(orchestrator: AgentOrchestrator) async -> SlashCommandResult {
        let items = await DiagnosticManager.runSelfCheck(provider: orchestrator)

        let lines = items.map { item in
            let icon = item.status == .pass ? "✅" : (item.status == .warning ? "⚠️" : "❌")
            return "| \(icon) \(item.name) | \(item.category) | \(item.status.rawValue) | \(item.message) |"
        }.joined(separator: "\n")

        let report = """
        🩺 **System Diagnostics Report**

        | Check | Category | Status | Details |
        | :--- | :--- | :--- | :--- |
        \(lines)
        """

        return SlashCommandResult(command: .diagnostics, outputMarkdown: report)
    }

    private func handleMemoryCommand(
        arg: String,
        botManager: BotManager?
    ) async -> SlashCommandResult {
        let query = arg.trimmingCharacters(in: .whitespacesAndNewlines)
        let memEngine = CognitiveMemoryEngine.shared

        if let activeBotId = botManager?.activeBotId {
            let facts = memEngine.retrieveRelevantContext(query: query.isEmpty ? "context" : query, botId: activeBotId)
            let episodes = memEngine.allEpisodes(forBotId: activeBotId)

            let factsText = facts.isEmpty ? "No matching semantic facts." : facts
            let recentEpisodes = episodes.suffix(3).map { "• [(\($0.timestamp.formatted(date: .omitted, time: .shortened)))] \($0.summary)" }.joined(separator: "\n")

            return SlashCommandResult(
                command: .memory,
                outputMarkdown: """
                🧠 **Cognitive Memory for Active Bot**

                **Semantic Facts:**
                \(factsText)

                **Recent Episodes (\(episodes.count) total):**
                \(recentEpisodes.isEmpty ? "No recorded episodes." : recentEpisodes)
                """
            )
        } else {
            return SlashCommandResult(
                command: .memory,
                outputMarkdown: "🧠 **Cognitive Memory Engine is active.** Select a bot or space channel to inspect bot-specific episodic and semantic facts."
            )
        }
    }

    private func handleAuditCommand() async -> SlashCommandResult {
        let workspace = FileManager.default.currentDirectoryPath
        let reports = await ProjectAuditor.shared.runWorkspaceAudit(at: workspace)

        if reports.isEmpty {
            return SlashCommandResult(
                command: .audit,
                outputMarkdown: "🛡️ **Project Audit Completed**: Workspace clean. No blocking issues or syntax regressions detected."
            )
        }

        let summary = reports.map { r in
            "• **\(r.name)** — \(r.fileCount) files, \(r.todoCount) TODOs, \(r.warnings.count) compiler warnings."
        }.joined(separator: "\n")

        return SlashCommandResult(
            command: .audit,
            outputMarkdown: """
            🛡️ **Workspace Audit Findings:**

            \(summary)
            """
        )
    }

    private func handleModelCommand(
        arg: String,
        orchestrator: AgentOrchestrator
    ) -> SlashCommandResult {
        let trimmed = arg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if trimmed.isEmpty {
            return SlashCommandResult(
                command: .model,
                outputMarkdown: """
                🤖 **Current Model Preference:** `\(orchestrator.modelPreference.rawValue)`

                To switch provider, type:
                `/model <auto | gemini | ollama | mlx | afm | pcc>`
                """
            )
        }

        let newPref: AgentModelPreference
        switch trimmed {
        case "auto", "autopicker":
            newPref = .autoPicker
        case "gemini", "cloud", "cloudgemini":
            newPref = .cloudGemini
        case "ollama", "localollama":
            newPref = .localOllama
        case "mlx", "localmlx":
            newPref = .localMLX
        case "afm", "localsystem", "device", "apple":
            newPref = .localSystem
        case "pcc", "privatecloud":
            newPref = .privateCloud
        default:
            return SlashCommandResult(
                command: .model,
                outputMarkdown: "⚠️ Unknown model option `\(arg)`. Choose from: `auto`, `gemini`, `ollama`, `mlx`, `afm`, `pcc`."
            )
        }

        orchestrator.modelPreference = newPref
        orchestrator.resetSession()

        return SlashCommandResult(
            command: .model,
            outputMarkdown: "✅ **Model provider switched to:** `\(newPref.rawValue)`. Session reset."
        )
    }
}
