import Foundation
import FoundationModels
import AppKit

struct DeepLinkTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "deep_link"
    let description = "Open deep links into Notes, Things 3, Fantastical, and other apps."

    @Generable
    struct Arguments: Codable {
        @Guide(description: "Action to perform ('notes_create', 'notes_search', 'notes_list', 'things_add', 'fantastical_add', 'open_url')")
        var action: String
        
        @Guide(description: "Title for note or task")
        var title: String?
        
        @Guide(description: "Body or notes for note or task")
        var body: String?
        
        @Guide(description: "Search query for 'notes_search'")
        var searchQuery: String?
        
        @Guide(description: "Due date for task or event")
        var dueDate: String?
        
        @Guide(description: "Priority for task")
        var priority: Int?
        
        @Guide(description: "URL for 'open_url' action")
        var url: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Opening deep links to external applications") {
            let action = arguments.action.lowercased()
            
            switch action {
            case "notes_create":
                guard let title = arguments.title, let body = arguments.body else { return "ERROR: Missing title or body parameters." }
                let escapedTitle = escapeForAppleScript(title)
                let escapedBody = escapeForAppleScript(body)
                let script = """
                tell application "Notes"
                    activate
                    make new note at folder "Notes" with properties {name:"\(escapedTitle)", body:"\(escapedBody)"}
                end tell
                """
                return await runAppleScript(script)
                
            case "notes_search":
                guard let query = arguments.searchQuery else { return "ERROR: Missing searchQuery parameter." }
                let escapedQuery = escapeForAppleScript(query)
                let script = """
                tell application "Notes"
                    set results to name of every note whose name contains "\(escapedQuery)"
                    return results as text
                end tell
                """
                return await runAppleScript(script)
                
            case "notes_list":
                let script = """
                tell application "Notes"
                    set noteList to name of notes 1 thru 10
                    return noteList as text
                end tell
                """
                return await runAppleScript(script)
                
            case "things_add":
                guard let title = arguments.title else { return "ERROR: Missing title parameter." }
                let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                var urlString = "things:///add?title=\(encodedTitle)"
                if let body = arguments.body {
                    let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    urlString += "&notes=\(encodedBody)"
                }
                if let dueDate = arguments.dueDate {
                    let encodedDate = dueDate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    urlString += "&when=\(encodedDate)"
                }
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                    return "✅ Opened URL: \(urlString)"
                } else {
                    return "ERROR: Invalid URL generated."
                }
                
            case "fantastical_add":
                guard let title = arguments.title else { return "ERROR: Missing title parameter." }
                let sentence = [title, arguments.dueDate].compactMap { $0 }.joined(separator: " ")
                guard let encodedSentence = sentence.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
                    return "ERROR: URL encoding failed."
                }
                let urlString = "x-fantastical3://parse?sentence=\(encodedSentence)"
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                    return "✅ Opened URL: \(urlString)"
                } else {
                    return "ERROR: Invalid URL generated."
                }
                
            case "open_url":
                guard let urlString = arguments.url, let url = URL(string: urlString) else { return "ERROR: Invalid URL" }
                NSWorkspace.shared.open(url)
                return "✅ Opened URL: \(url)"
                
            default:
                return "ERROR: Unsupported action '\(action)'"
            }
        }
    }
    
    private func escapeForAppleScript(_ input: String) -> String {
        return input
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
    
    private func runAppleScript(_ source: String) async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let appleScript = NSAppleScript(source: source)
                let result = appleScript?.executeAndReturnError(&error)

                if let error = error {
                    let errorMsg = error[NSAppleScript.errorMessage] as? String
                        ?? error[NSAppleScript.errorNumber].map { "Error \($0)" }
                        ?? "Unknown AppleScript error"
                    continuation.resume(returning: "ERROR: \(errorMsg)")
                } else if let result = result {
                    continuation.resume(returning: result.stringValue ?? "Success")
                } else {
                    continuation.resume(returning: "Success")
                }
            }
        }
    }
}
