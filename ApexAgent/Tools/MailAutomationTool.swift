import Foundation
import FoundationModels
import AppKit

struct MailAutomationTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "mail_automation"
    let description = "Mail inbox management via AppleScript."

    @Generable
    struct Arguments: Codable {
        @Guide(description: "Action to perform ('inbox', 'read', 'draft', 'search', 'move')")
        var action: String
        
        @Guide(description: "Message index for 'read' and 'move' actions")
        var messageIndex: Int?
        
        @Guide(description: "Subject for 'draft' action")
        var subject: String?
        
        @Guide(description: "To recipient for 'draft' action")
        var to: String?
        
        @Guide(description: "Body content for 'draft' action")
        var body: String?
        
        @Guide(description: "Target folder for 'move' action")
        var folder: String?
        
        @Guide(description: "Search query for 'search' action")
        var searchQuery: String?
        
        @Guide(description: "Limit for 'inbox' action (default 10)")
        var limit: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Reading/managing email via Mail.app") {
            let script: String
            let action = arguments.action.lowercased()
            
            switch action {
            case "inbox":
                let limit = arguments.limit ?? 10
                script = """
                tell application "Mail"
                    set msgs to messages of inbox whose read status is false
                    set output to ""
                    repeat with i from 1 to (count of msgs)
                        if i > \(limit) then exit repeat
                        set m to item i of msgs
                        set output to output & i & ". " & (sender of m) & " | " & (subject of m) & " | " & (date received of m) & linefeed
                    end repeat
                    return output
                end tell
                """
                
            case "read":
                guard let index = arguments.messageIndex else { return "ERROR: Missing messageIndex parameter." }
                script = """
                tell application "Mail"
                    set m to message \(index) of inbox
                    return (subject of m) & linefeed & linefeed & (content of m)
                end tell
                """
                
            case "draft":
                guard let subject = arguments.subject, let to = arguments.to, let body = arguments.body else {
                    return "ERROR: Missing subject, to, or body parameters."
                }
                let escapedSubject = escapeForAppleScript(subject)
                let escapedTo = escapeForAppleScript(to)
                let escapedBody = escapeForAppleScript(body)
                script = """
                tell application "Mail"
                    set newMsg to make new outgoing message with properties {subject:"\(escapedSubject)", content:"\(escapedBody)", visible:true}
                    tell newMsg to make new to recipient at end of to recipients with properties {address:"\(escapedTo)"}
                end tell
                """
                
            case "search":
                guard let query = arguments.searchQuery else { return "ERROR: Missing searchQuery parameter." }
                let escapedQuery = escapeForAppleScript(query)
                script = """
                tell application "Mail"
                    set msgs to messages of inbox whose subject contains "\(escapedQuery)"
                    set output to ""
                    repeat with i from 1 to (count of msgs)
                        if i > 10 then exit repeat
                        set m to item i of msgs
                        set output to output & i & ". " & (sender of m) & " | " & (subject of m) & " | " & (date received of m) & linefeed
                    end repeat
                    return output
                end tell
                """
                
            case "move":
                guard let index = arguments.messageIndex, let folder = arguments.folder else {
                    return "ERROR: Missing messageIndex or folder parameters."
                }
                let escapedFolder = escapeForAppleScript(folder)
                script = """
                tell application "Mail"
                    set m to message \(index) of inbox
                    set targetMailbox to mailbox "\(escapedFolder)"
                    move m to targetMailbox
                end tell
                """
                
            default:
                return "ERROR: Unsupported action '\(action)'"
            }
            
            return await runAppleScript(script)
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
