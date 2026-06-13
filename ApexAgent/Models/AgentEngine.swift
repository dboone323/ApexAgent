import Foundation
import AppKit
import FoundationModels

// MARK: - Agent Engine Protocol

@MainActor
protocol AgentEngine {
    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws
}

// MARK: - Native Apple Engine (macOS 27 native models)

@MainActor
struct NativeAppleEngine: AgentEngine {
    let orchestrator: AgentOrchestrator

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        // NativeAppleEngine uses the active LanguageModelSession managed by AgentOrchestrator
        guard let session = orchestrator.session else {
            throw NSError(domain: "NativeAppleEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "LanguageModelSession is not initialized."])
        }

        var options = GenerationOptions()
        options.toolCallingMode = switch toolCallingMode {
        case .auto: .allowed
        case .required: .required
        case .disabled: .disallowed
        }

        // Extract semantic RAG context (the portion appended to orchestrator.agentInstructions)
        let semanticContext = instructions.replacingOccurrences(of: orchestrator.agentInstructions, with: "")
        let promptWithContext = prompt + semanticContext

        if !attachments.isEmpty {
            let stream = session.streamResponse(options: options) {
                promptWithContext
                for attachment in attachments {
                    Attachment(attachment)
                }
            }
            for try await partialResponse in stream {
                await onUpdate(partialResponse.content)
            }
        } else {
            let stream = session.streamResponse(to: promptWithContext, options: options)
            for try await partialResponse in stream {
                await onUpdate(partialResponse.content)
            }
        }
    }
}


// MARK: - Helper Utilities & JSON Schemas

func base64String(from image: NSImage) -> String? {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    return pngData.base64EncodedString()
}

@MainActor
func getParsedSchemas() -> [[String: Any]] {
    guard let data = RAW_TOOL_SCHEMAS_JSON.data(using: .utf8),
          var array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    // Inject dynamic tools
    let dynamicSchemas = DynamicToolbox.shared.dynamicTools.values.map { $0.schema }
    array.append(contentsOf: dynamicSchemas)
    return array
}

@MainActor
func getParsedGeminiFunctionDeclarations() -> [[String: Any]] {
    let schemas = getParsedSchemas()
    
    // Gemini wants uppercase types for properties, e.g. "STRING", "INTEGER", "BOOLEAN", "OBJECT"
    func convertTypesUppercase(_ dict: [String: Any]) -> [String: Any] {
        var copy = dict
        if let type = copy["type"] as? String {
            copy["type"] = type.uppercased()
        }
        if let properties = copy["properties"] as? [String: Any] {
            var newProps: [String: Any] = [:]
            for (k, v) in properties {
                if let vDict = v as? [String: Any] {
                    newProps[k] = convertTypesUppercase(vDict)
                } else {
                    newProps[k] = v
                }
            }
            copy["properties"] = newProps
        }
        return copy
    }

    return schemas.map { schema in
        var decl = schema
        if let params = decl["parameters"] as? [String: Any] {
            decl["parameters"] = convertTypesUppercase(params)
        }
        return decl
    }
}

@MainActor
func getParsedSchemasJSONData() -> Data {
    let schemas = getParsedSchemas()
    return (try? JSONSerialization.data(withJSONObject: schemas)) ?? Data()
}

@MainActor
func getParsedGeminiFunctionDeclarationsJSONData() -> Data {
    let decls = getParsedGeminiFunctionDeclarations()
    return (try? JSONSerialization.data(withJSONObject: decls)) ?? Data()
}



private let RAW_TOOL_SCHEMAS_JSON = """
[
  {
    "name": "run_shell_command",
    "description": "Runs a zsh shell command. Returns stdout, stderr, and exit code. Use for any terminal task.",
    "parameters": {
      "type": "object",
      "properties": {
        "command": { "type": "string", "description": "The shell command to execute. Will be run via /bin/zsh -c" },
        "workingDirectory": { "type": "string", "description": "Working directory for the command. Defaults to user home if not specified." },
        "timeoutSeconds": { "type": "integer", "description": "Timeout in seconds before the command is killed. Default is 30." }
      },
      "required": ["command"]
    }
  },
  {
    "name": "read_file",
    "description": "Reads a file and returns its contents. Supports tilde paths (~/).",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Absolute or tilde-expanded path to the file to read" },
        "maxLines": { "type": "integer", "description": "Maximum number of lines to read. Reads entire file if not specified." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "write_file",
    "description": "Writes text content to a file. Creates the file and parent directories if needed.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Absolute or tilde-expanded path to write to" },
        "content": { "type": "string", "description": "The text content to write to the file" },
        "append": { "type": "boolean", "description": "If true, appends to existing file instead of overwriting" }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "list_directory",
    "description": "Lists files and subdirectories at a path with sizes. Supports tilde paths.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the directory to list" },
        "showHidden": { "type": "boolean", "description": "If true, shows hidden files (starting with .)" },
        "depth": { "type": "integer", "description": "Maximum depth for recursive listing. 1 = only immediate children." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "create_directory",
    "description": "Creates a directory (including parent directories) at the given path.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path of the directory to create" }
      },
      "required": ["path"]
    }
  },
  {
    "name": "delete_file",
    "description": "Moves a file or directory to Trash (or permanently deletes if permanent=true). DESTRUCTIVE.",
    "parameters": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path of the file or directory to delete" },
        "permanent": { "type": "boolean", "description": "If true, permanently deletes instead of moving to Trash. DANGEROUS." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "move_file",
    "description": "Moves or renames a file or directory from source to destination.",
    "parameters": {
      "type": "object",
      "properties": {
        "sourcePath": { "type": "string", "description": "Source path of the file/directory to move" },
        "destinationPath": { "type": "string", "description": "Destination path (including new filename if renaming)" }
      },
      "required": ["sourcePath", "destinationPath"]
    }
  },
  {
    "name": "web_search",
    "description": "Searches the web using Brave Search (primary) with DuckDuckGo as fallback. Returns the top search results including titles, URLs, and text snippets.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "The search query to look up on the web" },
        "count": { "type": "integer", "description": "Number of results to return" }
      },
      "required": ["query"]
    }
  },
  {
    "name": "run_applescript",
    "description": "Executes an AppleScript string and returns the result. Use this to control any scriptable macOS application (Finder, Safari, Chrome, System Settings, etc.).",
    "parameters": {
      "type": "object",
      "properties": {
        "script": { "type": "string", "description": "The AppleScript code to execute" }
      },
      "required": ["script"]
    }
  },
  {
    "name": "take_screenshot",
    "description": "Captures a screenshot of the entire screen and saves it to a PNG file. Returns the file path. Requires Screen Recording permission.",
    "parameters": {
      "type": "object",
      "properties": {
        "savePath": { "type": "string", "description": "Path to save the screenshot PNG. Defaults to ~/Desktop/apex_screenshot_<timestamp>.png" },
        "windowOnly": { "type": "boolean", "description": "If true, captures only the frontmost window instead of the full screen" }
      }
    }
  },
  {
    "name": "read_clipboard",
    "description": "Reads the current text content of the macOS clipboard (pasteboard) and returns it.",
    "parameters": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "write_clipboard",
    "description": "Sets the macOS clipboard (pasteboard) to the specified text content.",
    "parameters": {
      "type": "object",
      "properties": {
        "text": { "type": "string", "description": "The text to copy to the clipboard" }
      },
      "required": ["text"]
    }
  },
  {
    "name": "send_notification",
    "description": "Sends a macOS user notification that appears in Notification Center. Use this to alert the user when a long-running task completes.",
    "parameters": {
      "type": "object",
      "properties": {
        "title": { "type": "string", "description": "The title of the notification" },
        "body": { "type": "string", "description": "The body text of the notification" },
        "subtitle": { "type": "string", "description": "Optional subtitle shown below the title" }
      },
      "required": ["title", "body"]
    }
  },
  {
    "name": "get_system_info",
    "description": "Returns detailed information about the macOS system including OS version, hardware model, chip, RAM, storage, and network info.",
    "parameters": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "get_running_processes",
    "description": "Returns a list of currently running macOS applications (user-visible apps, not background daemons).",
    "parameters": {
      "type": "object",
      "properties": {
        "includeBackground": { "type": "boolean", "description": "If true, includes background/hidden processes. If false (default), only shows user-visible apps." }
      }
    }
  },
  {
    "name": "get_frontmost_app",
    "description": "Returns the bundle ID, name, and process ID of the currently active (frontmost) macOS application.",
    "parameters": {
      "type": "object",
      "properties": {}
    }
  },
  {
    "name": "store_memory",
    "description": "Stores or updates a key-value memory record in the on-device SQLite database. Use this to remember important system locations, file changes, or status of long-running tasks.",
    "parameters": {
      "type": "object",
      "properties": {
        "key": { "type": "string", "description": "The topic or identifier for this memory (e.g., 'task_status', 'project_root')" },
        "value": { "type": "string", "description": "The detailed value/notes to remember" }
      },
      "required": ["key", "value"]
    }
  },
  {
    "name": "search_memory",
    "description": "Searches the long-term SQLite memory database for entries matching the query keyword.",
    "parameters": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "Search keyword to match against keys or values. If empty, lists the most recent memories." }
      }
    }
  },
  {
    "name": "control_app",
    "description": "Performs reliable, pre-tested GUI automation actions on common macOS apps (Safari, Chrome, Finder, System Settings).",
    "parameters": {
      "type": "object",
      "properties": {
        "appName": { "type": "string", "description": "Target application ('Safari', 'Chrome', 'Finder', 'System Settings')" },
        "action": { "type": "string", "description": "Action to perform ('open_url', 'get_active_tab', 'open_folder', 'get_selected', 'open_preference_pane')" },
        "parameter": { "type": "string", "description": "Argument for the action (e.g., URL for 'open_url', folder path for 'open_folder', pane ID for 'open_preference_pane')" }
      },
      "required": ["appName", "action"]
    }
  },
  {
    "name": "control_accessibility",
    "description": "Performs UI automation actions on the active application window using accessibility (AXUIElement) APIs. Requires Accessibility permissions.",
    "parameters": {
      "type": "object",
      "properties": {
        "action": { "type": "string", "description": "The action to perform: 'list_elements', 'click', 'set_text', 'focus'" },
        "elementId": { "type": "string", "description": "The registry ID of the element (e.g. 'elem_1') - required for click, set_text, focus" },
        "textValue": { "type": "string", "description": "The text value to enter - required for set_text" }
      },
      "required": ["action"]
    }
  },
  {
    "name": "control_browser",
    "description": "Controls a headless, windowless web browser (Safari/WebKit based) to open pages, scrape content, click elements, and fill forms.",
    "parameters": {
      "type": "object",
      "properties": {
        "action": { "type": "string", "description": "The action to perform: 'open_url', 'scrape_page', 'click_element', 'input_text'" },
        "url": { "type": "string", "description": "The URL to navigate to - required for open_url" },
        "selector": { "type": "string", "description": "CSS selector for the target element - required for click_element and input_text" },
        "textValue": { "type": "string", "description": "The text value to input - required for input_text" }
      },
      "required": ["action"]
    }
  },
  {
    "name": "update_plan",
    "description": "Sets or updates the current execution plan steps to be visualized in the Plan Dashboard.",
    "parameters": {
      "type": "object",
      "properties": {
        "steps": {
          "type": "array",
          "description": "The list of plan steps",
          "items": {
            "type": "object",
            "properties": {
              "title": { "type": "string", "description": "The description of the step" },
              "status": { "type": "string", "description": "The status of the step: 'queued', 'running', 'completed', 'failed'" }
            },
            "required": ["title", "status"]
          }
        }
      },
      "required": ["steps"]
    }
  },
  {
    "name": "delegate_task",
    "description": "Delegates a specific sub-task to a specialized sub-agent (developer, executor, controller, researcher, linter, uiDesigner, planner) and returns their final response report.",
    "parameters": {
      "type": "object",
      "properties": {
        "agentType": { "type": "string", "description": "The type of sub-agent to delegate the task to (developer, executor, controller, researcher, linter, uiDesigner, planner)" },
        "taskDescription": { "type": "string", "description": "The detailed task instructions and context for the sub-agent to execute." }
      },
      "required": ["agentType", "taskDescription"]
    }
  },
  {
    "name": "convene_meeting",
    "description": "Convenes a round-robin debate among multiple specialized sub-agents to find consensus on a complex topic.",
    "parameters": {
      "type": "object",
      "properties": {
        "topic": { "type": "string", "description": "The discussion topic or problem to debate" },
        "participants": {
          "type": "array",
          "description": "List of sub-agent types participating (developer, executor, controller, researcher, linter, uiDesigner, planner)",
          "items": { "type": "string" }
        }
      },
      "required": ["topic", "participants"]
    }
  },
  {
    "name": "create_skill",
    "description": "Creates a new custom skill/tool by writing a shell or python script and registering its schema.",
    "parameters": {
      "type": "object",
      "properties": {
        "skillName": { "type": "string", "description": "Name of the skill to create (snake_case)" },
        "skillDescription": { "type": "string", "description": "Short description of what the skill does" },
        "scriptContent": { "type": "string", "description": "The zsh or python script content" },
        "parameterSchemaJSON": { "type": "string", "description": "The JSON Schema of the parameters this script expects" }
      },
      "required": ["skillName", "skillDescription", "scriptContent", "parameterSchemaJSON"]
    }
  },
  {
    "name": "run_workflow",
    "description": "Runs a pre-defined multi-agent state-graph workflow pipeline (Codex -> Auditor -> Nexus) to resolve a development task.",
    "parameters": {
      "type": "object",
      "properties": {
        "topic": { "type": "string", "description": "The task or bug description to solve using the pipeline" }
      },
      "required": ["topic"]
    }
  },
  {
    "name": "audit_projects",
    "description": "Audits Xcode projects in a directory for potential code style, warning, and configuration issues.",
    "parameters": {
      "type": "object",
      "properties": {
        "directoryPath": { "type": "string", "description": "The path to the directory containing Xcode projects to audit" }
      },
      "required": ["directoryPath"]
    }
  },
  {
    "name": "analyze_image",
    "description": "Analyzes the visual contents of a local image file based on a natural language query (multimodal visual QA).",
    "parameters": {
      "type": "object",
      "properties": {
        "imagePath": { "type": "string", "description": "Path to the local image file to analyze" },
        "query": { "type": "string", "description": "The visual query or question about the image content" }
      },
      "required": ["imagePath", "query"]
    }
  },
  {
    "name": "detect_image_text",
    "description": "Runs optical character recognition (OCR) on a local image file to extract readable text.",
    "parameters": {
      "type": "object",
      "properties": {
        "imagePath": { "type": "string", "description": "Path to the local image file to perform OCR on" }
      },
      "required": ["imagePath"]
    }
  }
]
"""


