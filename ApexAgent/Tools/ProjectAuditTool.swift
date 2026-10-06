import Foundation
import FoundationModels

struct ProjectAuditTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "audit_projects"
    let description = "Audits Swift/Xcode projects in the specified directory. Scans for targets, swift versions, strict concurrency compliance, and broken references."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The directory containing Xcode projects to audit. Defaults to the configured workspace (apex.workspacePath), else the user's ~/Developer folder or home directory.")
        var directoryPath: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let wsPath = await MainActor.run { self.orchestrator.orchestrator.currentWorkspacePath }
            let path: String
            if let provided = arguments.directoryPath, !provided.isEmpty {
                // Resolve relative paths (".", "./", etc.) against the workspace
                let expanded = NSString(string: provided).expandingTildeInPath
                if expanded.hasPrefix("/") {
                    path = expanded
                } else if expanded == "." || expanded == "./" {
                    path = wsPath
                } else {
                    path = (wsPath as NSString).appendingPathComponent(expanded)
                }
            } else {
                path = wsPath.isEmpty ? AgentOrchestrator.proactiveAuditWorkspacePath() : wsPath
            }
            let auditor = await ProjectAuditor.shared
            let reports = await auditor.runWorkspaceAudit(at: path)
            
            if reports.isEmpty {
                return "No Xcode projects found in '\(path)'."
            }
            
            return await auditor.formatReportsAsMarkdown(reports)
        }
    }
}
