import Foundation
import FoundationModels
import AppKit

struct ApplicationControlTool: Tool {
    let name = "control_app"
    let description = "Performs reliable, pre-tested GUI automation actions on common macOS apps (Safari, Chrome, Finder, System Settings)."

    @Generable
    struct Arguments: Codable {
        @Guide(description: "Target application ('Safari', 'Chrome', 'Finder', 'System Settings')")
        var appName: String

        @Guide(description: "Action to perform ('open_url', 'get_active_tab', 'open_folder', 'get_selected', 'open_preference_pane')")
        var action: String

        @Guide(description: "Argument for the action (e.g., URL for 'open_url', folder path for 'open_folder', pane ID for 'open_preference_pane')")
        var parameter: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, riskDescription: "Controlling \(arguments.appName) using system AppleScript") {
            let script: String
            
            switch (arguments.appName.lowercased(), arguments.action.lowercased()) {
            case ("safari", "open_url"):
                guard let url = arguments.parameter else { return "ERROR: Missing URL parameter." }
                let escapedUrl = escapeAppleScriptParameter(url)
                script = """
                tell application "Safari"
                    activate
                    if not (exists window 1) then
                        make new document
                    end if
                    set URL of document 1 to "\(escapedUrl)"
                end tell
                """
                
            case ("safari", "get_active_tab"):
                script = """
                tell application "Safari"
                    if exists (window 1) then
                        return (name of current tab of window 1) & "\\n" & (URL of current tab of window 1)
                    else
                        return "No windows open"
                    end if
                end tell
                """
                
            case ("chrome", "open_url"):
                guard let url = arguments.parameter else { return "ERROR: Missing URL parameter." }
                let escapedUrl = escapeAppleScriptParameter(url)
                script = """
                tell application "Google Chrome"
                    activate
                    if not (exists window 1) then
                        make new window
                    end if
                    set URL of active tab of window 1 to "\(escapedUrl)"
                end tell
                """
                
            case ("chrome", "get_active_tab"):
                script = """
                tell application "Google Chrome"
                    if exists (window 1) then
                        return (title of active tab of window 1) & "\\n" & (URL of active tab of window 1)
                    else
                        return "No windows open"
                    end if
                end tell
                """
                
            case ("finder", "open_folder"):
                guard let rawPath = arguments.parameter else { return "ERROR: Missing folder path parameter." }
                let expandedPath = NSString(string: rawPath).expandingTildeInPath
                let escapedPath = escapeAppleScriptParameter(expandedPath)
                script = """
                tell application "Finder"
                    activate
                    open folder (POSIX file "\(escapedPath)")
                end tell
                """
                
            case ("finder", "get_selected"):
                script = """
                tell application "Finder"
                    set selectedItems to selection
                    set output to ""
                    repeat with itemRef in selectedItems
                        set output to output & (POSIX path of (itemRef as text)) & "\\n"
                    end repeat
                    return output
                end tell
                """
                
            case ("system settings", "open_preference_pane"):
                guard let paneId = arguments.parameter else { return "ERROR: Missing preference pane ID parameter." }
                let escapedPaneId = escapeAppleScriptParameter(paneId)
                script = """
                tell application "System Settings"
                    activate
                    reveal pane id "\(escapedPaneId)"
                end tell
                """
                
            default:
                return "ERROR: Unsupported application '\(arguments.appName)' or action '\(arguments.action)'"
            }
            
            return await runAppleScript(script)
        }
    }
    
    private func escapeAppleScriptParameter(_ input: String) -> String {
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
