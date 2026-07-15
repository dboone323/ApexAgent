import Foundation
import FoundationModels
import SwiftData
import SharedKit

// MARK: - Save Review Session Tool
struct SaveReviewSessionTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "save_review_session"
    let description = "Saves code review findings (summary, suggestions, file metrics, issues) to the database."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The name of the file reviewed.")
        var fileName: String
        @Guide(description: "A summary of the code review.")
        var summary: String
        @Guide(description: "List of general suggestions.")
        var suggestions: [String]
        @Guide(description: "JSON array string of specific issues. Each issue should have: line (Int), message (String), and severity (String: 'info', 'warning', 'error').")
        var issuesJSON: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            try await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                let decoder = JSONDecoder()
                struct RawCodeIssue: Decodable {
                    let line: Int
                    let message: String
                    let severity: String
                }
                
                var issueModels: [CodeIssueModel] = []
                if let data = arguments.issuesJSON.data(using: .utf8),
                   let rawIssues = try? decoder.decode([RawCodeIssue].self, from: data) {
                    for raw in rawIssues {
                        let severity: ReviewSeverity
                        switch raw.severity.lowercased() {
                        case "warning": severity = .warning
                        case "error": severity = .error
                        default: severity = .info
                        }
                        let issue = CodeIssueModel(line: raw.line, message: raw.message, severity: severity)
                        issueModels.append(issue)
                    }
                }
                
                let session = ReviewSession(
                    fileName: arguments.fileName,
                    summary: arguments.summary,
                    suggestions: arguments.suggestions
                )
                session.issues = issueModels
                
                context.insert(session)
                for issue in issueModels {
                    issue.session = session
                    context.insert(issue)
                }
                
                try context.save()
                return "SUCCESS: Review session for '\(session.fileName)' saved with \(issueModels.count) specific issues."
            }
        }
    }
}

// MARK: - List Review Sessions Tool
struct ListReviewSessionsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "list_review_sessions"
    let description = "Lists past code review sessions stored in the database."

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                let descriptor = FetchDescriptor<ReviewSession>()
                guard let sessions = try? context.fetch(descriptor) else {
                    return "ERROR: Failed to fetch review sessions."
                }
                
                if sessions.isEmpty {
                    return "No review sessions found."
                }
                
                var result = "## Code Review History:\n\n"
                for session in sessions {
                    result += "• **\(session.fileName)** (Date: \(session.createdAt))\n"
                    result += "  - Summary: \(session.summary)\n"
                    result += "  - Issues count: \(session.issues.count)\n"
                    if !session.issues.isEmpty {
                        result += "  - Issues:\n"
                        for issue in session.issues {
                            result += "    * [Line \(issue.line)] [\(issue.severity)] \(issue.message)\n"
                        }
                    }
                    if !session.suggestions.isEmpty {
                        result += "  - Suggestions:\n"
                        for suggestion in session.suggestions {
                            result += "    * \(suggestion)\n"
                        }
                    }
                    result += "\n"
                }
                return result
            }
        }
    }
}
