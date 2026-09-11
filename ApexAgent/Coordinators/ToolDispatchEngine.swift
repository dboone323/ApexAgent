import Foundation
import SharedKit

// MARK: - Tool Dispatch Engine
//
// Encapsulates execution, speculative tool resolution, enterprise capability validation,
// audit recording, and user approval workflows.

@MainActor
final class ToolDispatchEngine: Sendable {
    static let dangerousToolNames: Set<String> = [
        "run_shell_command", "delete_file", "write_file", "run_applescript", "create_skill"
    ]
    static let confirmationTimeoutSeconds: TimeInterval = 60
    static let maxToolEventCount: Int = 200

    init() {}

    func buildAllTools(orchestrator: AgentOrchestrator, botManager: BotManager?) -> [AnyExecutableTool] {
        [
            AnyExecutableTool(ShellTool(orchestrator: orchestrator)),
            AnyExecutableTool(FileReadTool(orchestrator: orchestrator)),
            AnyExecutableTool(FileWriteTool(orchestrator: orchestrator)),
            AnyExecutableTool(ListDirectoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(CreateDirectoryTool(orchestrator: orchestrator)),
            AnyExecutableTool(DeleteFileTool(orchestrator: orchestrator)),
            AnyExecutableTool(MoveFileTool(orchestrator: orchestrator)),
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
            AnyExecutableTool(AskBotTool(botManager: botManager)),
            AnyExecutableTool(ConfirmCompletionTool(orchestrator: orchestrator)),
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
            AnyExecutableTool(DispatchSwarmTool(botManager: botManager))
        ]
    }

    func executeToolByName(name: String, jsonArguments: String, allTools: [AnyExecutableTool]) async throws -> String {
        do {
            // Enterprise zero-trust capability validation
            if !AgentSecurity.validateCapabilityToken(for: name, botName: nil) {
                throw NSError(domain: "AgentSecurity", code: 403, userInfo: [NSLocalizedDescriptionKey: "Enterprise Security: Missing or expired capability token for high-risk tool '\(name)'"])
            }
            
            let result: String
            if let speculativeResult = await SpeculativeToolExecutor.shared.resolve(toolName: name, jsonArguments: jsonArguments) {
                result = speculativeResult
            } else if let tool = allTools.first(where: { $0.name == name }) {
                result = try await tool.execute(jsonArguments: jsonArguments)
            } else if DynamicToolbox.shared.dynamicTools[name] != nil {
                result = try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: jsonArguments)
            } else {
                throw NSError(domain: "AgentOrchestrator", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unknown tool: \(name)"])
            }
            
            // Invalidate cache if a write tool executes
            let speculableToolNames: Set<String> = [
                "read_file", "file_search", "list_directory",
                "get_system_info", "search_memory", "query_logs"
            ]
            if !speculableToolNames.contains(name) {
                SpeculativeToolExecutor.shared.invalidateAll()
            }
            
            // Audit log
            CryptographicAuditChain.shared.record(
                toolName: name,
                input: jsonArguments,
                output: String(result.prefix(500)),
                status: "success",
                botName: nil
            )
            
            return result
        } catch {
            CryptographicAuditChain.shared.record(
                toolName: name,
                input: jsonArguments,
                output: error.localizedDescription,
                status: "error",
                botName: nil
            )
            throw error
        }
    }

    func shouldConfirmTool(name: String, requireConfirmationForAll: Bool) -> Bool {
        if requireConfirmationForAll { return true }
        return Self.dangerousToolNames.contains(name) || AgentSecurity.requiresConfirmation(name)
    }
}
