import Foundation
import FoundationModels

struct ProjectAuditTool: Tool {
    let name = "audit_projects"
    let description = "Audits Swift/Xcode projects in the specified directory. Scans for targets, swift versions, strict concurrency compliance, and broken references."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The directory containing Xcode projects to audit. Defaults to '~/github-projects/fleet/apps'.")
        var directoryPath: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            let path = arguments.directoryPath ?? "~/github-projects/fleet/apps"
            let auditor = await ProjectAuditor.shared
            let reports = await auditor.runWorkspaceAudit(at: path)
            
            if reports.isEmpty {
                return "No Xcode projects found in '\(path)'."
            }
            
            var output = "📊 Swift/Xcode Project Workspace Audit Report\n"
            output += "Directory: \(path)\n\n"
            
            for report in reports {
                output += "### 📦 App: \(report.name)\n"
                output += "- **Path**: \(report.path)\n"
                output += "- **Swift Version**: \(report.swiftVersion)\n"
                output += "- **Strict Concurrency**: \(report.strictConcurrency)\n"
                output += "- **Deployment Target**: \(report.deploymentTarget)\n"
                output += "- **Swift Files Count**: \(report.fileCount)\n"
                output += "- **TODO/FIXME Count**: \(report.todoCount)\n"
                
                if !report.brokenReferences.isEmpty {
                    output += "- **⚠️ Broken References (\(report.brokenReferences.count))**:\n"
                    for ref in report.brokenReferences {
                        output += "  - \(ref)\n"
                    }
                } else {
                    output += "- **Broken References**: None\n"
                }
                
                if !report.warnings.isEmpty {
                    output += "- **⚠️ Compliance Warnings (\(report.warnings.count))**:\n"
                    for warning in report.warnings {
                        output += "  - \(warning)\n"
                    }
                } else {
                    output += "- **Compliance Warnings**: None\n"
                }
                output += "\n"
            }
            
            return output
        }
    }
}
