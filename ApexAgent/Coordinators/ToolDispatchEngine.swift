import Foundation
import SharedKit

// MARK: - Tool Dispatch Engine
//
// Encapsulates execution, speculative tool resolution, enterprise capability validation,
// audit recording, and user approval workflows.

@MainActor
final class ToolDispatchEngine {
    /// Single source of truth for the dangerous-tool set. AgentOrchestrator's
    /// confirmation path reads this via shouldConfirmTool (do not duplicate).
    static let dangerousToolNames: Set<String> = [
        "run_shell_command", "delete_file", "write_file", "run_applescript", "create_skill"
    ]
    static let confirmationTimeoutSeconds: TimeInterval = 60
    static let maxToolEventCount: Int = 200

    init() {}

    func shouldConfirmTool(name: String, requireConfirmationForAll: Bool = false) -> Bool {
        if requireConfirmationForAll { return true }
        return Self.dangerousToolNames.contains(name)
    }

    func buildAllTools(orchestrator: AgentOrchestrator, botManager: BotManager?) -> [AnyExecutableTool] {
        [
            AnyExecutableTool(ShellTool(orchestrator: orchestrator)),
            AnyExecutableTool(FileReadTool(orchestrator: orchestrator)),
            AnyExecutableTool(FileWriteTool(orchestrator: orchestrator)),
            AnyExecutableTool(ListDirectoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(CreateDirectoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(DeleteFileTool(orchestrator: orchestrator)),
            AnyExecutableTool(MoveFileTool(orchestrator: orchestrator)),
            AnyExecutableTool(RollbackTool(orchestrator: orchestrator)),
            AnyExecutableTool(WebSearchTool(orchestrator: orchestrator)),
            AnyExecutableTool(AppleScriptTool(orchestrator: orchestrator)),
            AnyExecutableTool(ScreenshotTool(orchestrator: orchestrator)),
            AnyExecutableTool(ClipboardReadTool(orchestrator: orchestrator)),
            AnyExecutableTool(ClipboardWriteTool(orchestrator: orchestrator)),
            AnyExecutableTool(NotificationTool(orchestrator: orchestrator)),
            AnyExecutableTool(SystemInfoTool(orchestrator: orchestrator)),
            AnyExecutableTool(ProcessListTool(orchestrator: orchestrator)),
            AnyExecutableTool(GetFrontmostAppTool(orchestrator: orchestrator)),
            AnyExecutableTool(StoreMemoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(SearchMemoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(ApplicationControlTool(orchestrator: orchestrator)),
            AnyExecutableTool(AccessibilityControlTool(orchestrator: orchestrator)),
            AnyExecutableTool(AccessibilityOmniTargeter(orchestrator: orchestrator)),
            AnyExecutableTool(DifferentialScreenPerception(orchestrator: orchestrator)),
            AnyExecutableTool(CaptureWindowImageTool(orchestrator: orchestrator)),
            AnyExecutableTool(BrowserAutomationTool(orchestrator: orchestrator)),
            AnyExecutableTool(UpdatePlanTool(orchestrator: orchestrator)),
            AnyExecutableTool(ProjectAuditTool(orchestrator: orchestrator)),
            AnyExecutableTool(DelegateTaskTool(orchestrator: orchestrator)),
            AnyExecutableTool(AnalyzeImageTool(orchestrator: orchestrator)),
            AnyExecutableTool(DetectImageTextTool(orchestrator: orchestrator)),
            AnyExecutableTool(ConveneMeetingTool(orchestrator: orchestrator)),
            AnyExecutableTool(CreateSkillTool(orchestrator: orchestrator)),
            AnyExecutableTool(RunWorkflowTool(orchestrator: orchestrator)),
            AnyExecutableTool(FileSearchTool(orchestrator: orchestrator)),
            AnyExecutableTool(SpotlightSearchTool(orchestrator: orchestrator)),
            AnyExecutableTool(DynamicToolCallTool(orchestrator: orchestrator)),
            AnyExecutableTool(DailyBriefingTool(orchestrator: orchestrator)),
            AnyExecutableTool(AskBotTool(orchestrator: orchestrator)),
            AnyExecutableTool(ConfirmCompletionTool(orchestrator: orchestrator)),
            AnyExecutableTool(VerifyExecutionTool(orchestrator: orchestrator)),
            AnyExecutableTool(SaveReviewSessionTool(orchestrator: orchestrator)),
            AnyExecutableTool(ListReviewSessionsTool(orchestrator: orchestrator)),
            AnyExecutableTool(WeatherTool(orchestrator: orchestrator)),
            AnyExecutableTool(MapSearchTool(orchestrator: orchestrator)),
            AnyExecutableTool(DirectionsTool(orchestrator: orchestrator)),
            AnyExecutableTool(CalendarTool(orchestrator: orchestrator)),
            AnyExecutableTool(ReminderTool(orchestrator: orchestrator)),
            AnyExecutableTool(TranslateTool(orchestrator: orchestrator)),
            AnyExecutableTool(EntityExtractTool(orchestrator: orchestrator)),
            AnyExecutableTool(AppleShortcutsTool(orchestrator: orchestrator)),
            AnyExecutableTool(OSLogQueryTool(orchestrator: orchestrator)),
            AnyExecutableTool(WatchPathsTool(orchestrator: orchestrator)),
            AnyExecutableTool(NetworkDiagnosticsTool(orchestrator: orchestrator)),
            AnyExecutableTool(ScreenPerceptionTool(orchestrator: orchestrator)),
            AnyExecutableTool(FilePatchTool(orchestrator: orchestrator)),
            AnyExecutableTool(GitOperationsTool(orchestrator: orchestrator)),
            AnyExecutableTool(DispatchSwarmTool(orchestrator: orchestrator, botManager: botManager)),
            // M3: these tools were fully implemented but never registered,
            // so the agent could not call them at all.
            AnyExecutableTool(ComputerUseTool(orchestrator: orchestrator)),
            AnyExecutableTool(GitHubTool(orchestrator: orchestrator)),
            AnyExecutableTool(ContainerStatusTool(orchestrator: orchestrator)),
            AnyExecutableTool(SimctlTool(orchestrator: orchestrator)),
            AnyExecutableTool(MailAutomationTool(orchestrator: orchestrator)),
            AnyExecutableTool(DiscordBotTool(orchestrator: orchestrator)),
            AnyExecutableTool(DiscordWebhookTool(orchestrator: orchestrator)),
            AnyExecutableTool(DeepLinkTool(orchestrator: orchestrator))
        ]
    }

    func executeToolByName(
        name: String,
        jsonArguments: String,
        allTools: [AnyExecutableTool],
        bot: BotProfile? = nil,
        agentIdentity: AgentIdentity? = nil
    ) async throws -> String {
        // Workstream 5.6: Global Tool Governance policy enforcement
        guard ToolPolicy.shared.isGloballyAllowed(name) else {
            throw NSError(
                domain: "AgentSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Security Policy Denied: Tool '\(name)' has been disabled globally by security policy."]
            )
        }

        // RBAC Allowlist enforcement: If a Bot defines allowed tools, reject any disallowed tool
        if let bot = bot, !bot.allowedToolNames.isEmpty {
            if !bot.allowedToolNames.contains(name) {
                let err = NSError(
                    domain: "AgentSecurity",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Permission Denied: Bot '\(bot.name)' is not authorized to execute tool '\(name)'. Allowed tools: \(bot.allowedToolNames.joined(separator: ", "))"]
                )
                throw err
            }
        }

        // MCP Scoping enforcement: If a Bot defines allowed MCP servers, check dynamic MCP tools
        if let bot = bot, !bot.allowedMCPServers.isEmpty {
            if let entry = DynamicToolbox.shared.dynamicTools[name], let serverId = entry.mcpServerId {
                let matchingServer = MCPManager.shared.servers.first(where: { $0.id == serverId })
                let serverName = matchingServer?.name ?? ""
                let serverIdStr = serverId.uuidString
                let isAllowed = bot.allowedMCPServers.contains { allowed in
                    allowed.caseInsensitiveCompare(serverName) == .orderedSame ||
                    allowed.caseInsensitiveCompare(serverIdStr) == .orderedSame
                }
                if !isAllowed {
                    let displayName = serverName.isEmpty ? serverIdStr : serverName
                    let err = NSError(
                        domain: "AgentSecurity",
                        code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "ERROR: Tool '\(name)' from MCP server '\(displayName)' is not permitted for bot '\(bot.name)' under least-privilege MCP scoping policy. Allowed MCP servers: \(bot.allowedMCPServers.joined(separator: ", "))"]
                    )
                    throw err
                }
            }
        }

        guard AgentSecurity.isAllowed(name) else {
            throw NSError(
                domain: "AgentSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' is disabled by policy"]
            )
        }

        if let tool = allTools.first(where: { $0.name == name }) {
            return try await tool.execute(jsonArguments: jsonArguments)
        }

        if DynamicToolbox.shared.dynamicTools[name] != nil {
            return try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: jsonArguments)
        }

        throw NSError(
            domain: "AgentSecurity",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"]
        )
    }
}
