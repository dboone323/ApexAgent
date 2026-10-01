import Foundation

// MARK: - Intent-Based On-Demand Tool Selector
//
// Replaces "always-on 167-tool schema injection" with demand-driven tool gating
// and domain-scoped tool packs. This reduces per-turn prompt overhead from
// ~15,000+ tokens (63 native + 8 dynamic + 96 MCP schemas) down to 0 tokens on
// conversational/analytical turns and ~600–1,500 tokens (4–18 relevant schemas)
// on tool-enabled turns.

public struct IntentToolSelector: Sendable {

    // MARK: - Domain Tool Packs

    public static let coordinationPack: Set<String> = [
        "delegate_task", "convene_meeting", "dispatch_swarm", "ask_bot",
        "update_plan", "run_workflow", "confirm_completion", "send_notification"
    ]

    public static let filesystemPack: Set<String> = [
        "read_file", "write_file", "patch_file", "list_directory",
        "create_directory", "delete_file", "move_file", "file_search",
        "spotlight_search", "watch_paths"
    ]

    public static let gitAndReviewPack: Set<String> = [
        "git_operation", "github", "save_review_session",
        "list_review_sessions", "audit_projects"
    ]

    public static let systemAndShellPack: Set<String> = [
        "get_system_info", "run_shell_command", "run_applescript", "run_shortcut",
        "get_frontmost_app", "get_running_processes", "query_logs",
        "network_diagnostics", "manage_sandbox", "simctl"
    ]

    public static let desktopBrowserVisionPack: Set<String> = [
        "computer_use", "control_accessibility", "ax_target_element", "control_app",
        "control_browser", "read_clipboard", "write_clipboard", "take_screenshot",
        "capture_window_image", "screen_perception", "screen_diff",
        "analyze_image", "detect_image_text", "deep_link"
    ]

    public static let personalAndMemoryPack: Set<String> = [
        "store_memory", "search_memory", "calendar", "reminders", "mail_automation",
        "get_weather", "map_search", "get_directions", "web_search",
        "translate", "extract_entities", "daily_briefing",
        "discord_bot", "discord_webhook", "send_notification"
    ]

    public static let projectManagementPack: Set<String> = [
        "create_project", "create_sprint", "create_task", "update_task_status",
        "list_projects", "list_tasks", "list_sprints", "audit_projects", "update_plan"
    ]

    public static let dynamicSkillsPack: Set<String> = [
        "create_skill", "execute_dynamic_tool", "run_workflow",
        "build_gate", "container_probe", "e2e_smoke",
        "generate_macos_shortcut", "github_roundtrip",
        "macos_shortcut_generator", "monad", "monad_analogy"
    ]

    // MARK: - Explicit No-Tools Detection

    public static func isExplicitlyNoTools(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        // If the outer prompt explicitly asks to call an orchestration tool (like delegate_task or dispatch_swarm)
        // whose inner taskDescription says "without calling any tools", do NOT disable tools for the outer prompt.
        let hasOuterOrchestrationCall = lower.hasPrefix("call delegate_task")
            || lower.hasPrefix("call the delegate_task")
            || lower.hasPrefix("call convene_meeting")
            || lower.hasPrefix("call the convene_meeting")
            || lower.hasPrefix("call dispatch_swarm")
            || lower.hasPrefix("call the dispatch_swarm")
            || lower.hasPrefix("use delegate_task")
            || lower.hasPrefix("use convene_meeting")
            || lower.hasPrefix("use dispatch_swarm")
            || lower.hasPrefix("invoke delegate_task")
            || lower.hasPrefix("invoke convene_meeting")
            || lower.hasPrefix("invoke dispatch_swarm")

        if hasOuterOrchestrationCall {
            return false
        }

        return lower.contains("without tools")
            || lower.contains("without running tools")
            || lower.contains("without using tools")
            || lower.contains("without calling any tools")
            || lower.contains("without calling tools")
            || lower.contains("no tools")
            || lower.contains("don't use tools")
            || lower.contains("do not use tools")
            || lower.contains("without running any tools")
    }

    // MARK: - On-Demand Tool Gating

    /// Determines whether tool calling should be enabled for a given prompt.
    /// Returns `false` for conversational greetings, pure math/analytical questions,
    /// or conceptual Q&A that do not require any external tool execution.
    public static func shouldEnableTools(for prompt: String, hasAttachments: Bool = false) -> Bool {
        if isExplicitlyNoTools(prompt) {
            return false
        }
        if !hasAttachments && AgentOrchestrator.isConversationalGreetingOrSmallTalk(prompt) {
            return false
        }
        if hasAttachments {
            return true
        }

        let lower = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Conceptual Q&A / explanation prompts without explicit tool requests do not need tools
        let isConceptualQuestion = lower.hasPrefix("explain ")
            || lower.hasPrefix("what is the difference")
            || lower.hasPrefix("what's the difference")
            || lower.hasPrefix("why do ")
            || lower.hasPrefix("why does ")
            || lower.hasPrefix("define ")
            || lower.hasPrefix("state your ")
        let hasExplicitToolDirective = lower.contains("call ")
            || lower.contains("invoke ")
            || lower.contains("use tool")
            || lower.contains("get_system_info")
            || lower.contains("read_file")
            || lower.contains("delegate_task")
            || lower.contains("convene_meeting")
            || lower.contains("dispatch_swarm")
        if isConceptualQuestion && !hasExplicitToolDirective {
            return false
        }

        // Action / tool-intent indicators
        let actionKeywords: [String] = [
            "call ", "invoke ", "execute ", "use the ", "use tool", "tool",
            "delegate_task", "convene_meeting", "dispatch_swarm", "ask_bot",
            "delegate", "meeting", "swarm", "codex", "nexus", "auditor", "chronos", "oracle", "pilot", "aura",
            "file", "folder", "directory", "path", "workspace", "codebase", "repo", "repository",
            "read ", "write ", "patch ", "edit ", "create ", "delete ", "remove ", "move ", "rename ", "list ", "find ", "search",
            "git", "commit", "branch", "git diff", "diff ", "merge", "pull request", "pr ", "github", "issue",
            "shell", "terminal", "command", "bash", "zsh", "script", "applescript", "shortcut", "run ",
            "system_info", "get_system_info", "system info", "macos version", "cpu", "core count", "ram", "disk", "storage", "hostname",
            "process", "running app", "frontmost", "launch", "open ", "quit ", "close ",
            "browser", "website", "url", "http", "web", "click", "type ", "scroll", "selector", "accessibility", "window",
            "clipboard", "copy", "paste", "screenshot", "screen", "image", "ocr", "vision",
            "memory", "remember", "recall", "fact", "store_memory", "search_memory",
            "calendar", "schedule", "calendar event", "events", "meeting", "reminder", "todo", "mail", "email", "inbox",
            "weather", "forecast", "temperature", "map", "direction", "route", "location",
            "project", "task", "sprint", "backlog", "milestone", "audit", "lint", "review",
            "skill", "workflow", "playbook", "state_graph", "reflection", "standup",
            "container", "sandbox", "snapshot", "vm", "docker",
            "log", "oslog", "crash", "diagnostic", "network", "ping", "dns", "port",
            "simulator", "simctl", "xcode", "mcp", "lldb", "breakpoint", "coverage",
            "discord", "webhook", "notify", "notification", "deep_link", "deeplink",
            "translate", "entities", "extract"
        ]

        return actionKeywords.contains { lower.contains($0) }
    }

    // MARK: - MCP Server On-Demand Detection

    /// Returns `true` only when the prompt or environment requires spawning external MCP stdio servers.
    public static func requiresMCPServers(for prompt: String) -> Bool {
        if ProcessInfo.processInfo.environment["APEX_LOAD_MCP"] == "1" {
            return true
        }
        let lower = prompt.lowercased()
        let mcpKeywords = [
            "mcp", "xcodebuildmcp", "xcode-native", "mcpbridge",
            "build_macos", "test_macos", "build_run_macos", "launch_mac_app",
            "swift_package_", "debug_attach", "debug_breakpoint", "debug_lldb",
            "get_coverage", "get_file_coverage", "snapshot_ui", "wait_for_ui",
            "xcode_ide_", "buildproject", "runalltests", "runsometests",
            "renderpreview", "documentationsearch", "stringcatalog",
            "directory_tree", "read_multiple_files", "list_allowed_directories"
        ]
        return mcpKeywords.contains { lower.contains($0) }
    }

    // MARK: - Domain-Scoped Tool Filtering

    /// Selects only the relevant tool names for a prompt when no explicit `allowedTools` list is set.
    /// Keeps prompt token overhead minimal (~6–18 tools instead of 167) while guaranteeing that any
    /// explicitly named tool is always included.
    public static func selectRelevantToolNames(
        for prompt: String,
        allSchemas: [[String: Any]]
    ) -> [String] {
        if !shouldEnableTools(for: prompt) {
            return []
        }

        let lower = prompt.lowercased()
        let availableNames: [String] = allSchemas.compactMap { $0["name"] as? String }
        let availableSet = Set(availableNames)

        var selected = Set<String>()

        // 1. Always include any tool explicitly named in the prompt (exact or space-separated)
        for name in availableNames {
            let lowerName = name.lowercased()
            let spacedName = lowerName.replacingOccurrences(of: "_", with: " ")
            if lower.contains(lowerName) || (spacedName.count > 4 && lower.contains(spacedName)) {
                selected.insert(name)
            }
        }
        // Alias mapping: "system_info" <-> "get_system_info"
        if lower.contains("system_info") || lower.contains("system info") || lower.contains("macos version") || lower.contains("cpu") {
            if availableSet.contains("get_system_info") {
                selected.insert("get_system_info")
            }
        }

        // 2. If the user explicitly asked for a specific single tool ("Call the X tool..."),
        // and there are no multi-step connectors ("then", "after that", "next"), keep the toolset ultra-focused.
        let hasMultiStepConnector = lower.contains(" then ")
            || lower.contains(" and then ")
            || lower.contains(" after that ")
            || lower.contains(" next ")
            || lower.contains(" finally ")
        let isExplicitSingleToolCall = (lower.hasPrefix("call ") || lower.hasPrefix("invoke ") || lower.hasPrefix("use the "))
            && !selected.isEmpty
            && selected.count == 1
            && !hasMultiStepConnector
        if isExplicitSingleToolCall {
            return availableNames.filter { selected.contains($0) }
        }

        // 3. Domain pack matching
        if lower.contains("delegate") || lower.contains("meeting") || lower.contains("swarm")
            || lower.contains("bot") || lower.contains("codex") || lower.contains("nexus")
            || lower.contains("auditor") || lower.contains("chronos") || lower.contains("oracle")
            || lower.contains("pilot") || lower.contains("aura") || lower.contains("workflow")
            || lower.contains("plan") {
            selected.formUnion(coordinationPack)
        }

        if lower.contains("file") || lower.contains("folder") || lower.contains("directory")
            || lower.contains("read") || lower.contains("write") || lower.contains("patch")
            || lower.contains("edit") || lower.contains("code") || lower.contains("path")
            || lower.contains("search") || lower.contains("watch") {
            selected.formUnion(filesystemPack)
        }

        if lower.contains("git") || lower.contains("commit") || lower.contains("branch")
            || lower.contains("git diff") || lower.contains("diff ") || lower.contains("pr ")
            || lower.contains("pull request") || lower.contains("github") || lower.contains("review")
            || lower.contains("audit") || lower.contains("state_graph") {
            selected.formUnion(gitAndReviewPack)
        }

        if lower.contains("shell") || lower.contains("terminal") || lower.contains("command")
            || lower.contains("run") || lower.contains("bash") || lower.contains("zsh")
            || lower.contains("script") || lower.contains("applescript") || lower.contains("shortcut")
            || lower.contains("system") || lower.contains("cpu") || lower.contains("ram")
            || lower.contains("disk") || lower.contains("process") || lower.contains("log")
            || lower.contains("network") || lower.contains("ping") || lower.contains("dns")
            || lower.contains("container") || lower.contains("sandbox") || lower.contains("simulator")
            || lower.contains("simctl") {
            selected.formUnion(systemAndShellPack)
        }

        if lower.contains("app") || lower.contains("browser") || lower.contains("click")
            || lower.contains("type") || lower.contains("accessibility") || lower.contains("window")
            || lower.contains("clipboard") || lower.contains("screenshot") || lower.contains("screen")
            || lower.contains("image") || lower.contains("vision") || lower.contains("ocr")
            || lower.contains("selector") || lower.contains("deep_link") || lower.contains("deeplink") {
            selected.formUnion(desktopBrowserVisionPack)
        }

        if lower.contains("memory") || lower.contains("remember") || lower.contains("recall")
            || lower.contains("calendar") || lower.contains("schedule") || lower.contains("calendar event")
            || lower.contains("reminder") || lower.contains("mail") || lower.contains("email")
            || lower.contains("weather") || lower.contains("map") || lower.contains("direction")
            || lower.contains("web") || lower.contains("translate") || lower.contains("entit")
            || lower.contains("reflect") || lower.contains("discord") || lower.contains("notify")
            || lower.contains("notification") {
            selected.formUnion(personalAndMemoryPack)
        }

        if lower.contains("project") || lower.contains("task") || lower.contains("sprint")
            || lower.contains("backlog") || lower.contains("todo") || lower.contains("audit") {
            selected.formUnion(projectManagementPack)
        }

        if lower.contains("skill") || lower.contains("dynamic") || lower.contains("monad")
            || lower.contains("smoke") || lower.contains("probe") || lower.contains("gate")
            || lower.contains("shortcut") {
            selected.formUnion(dynamicSkillsPack)
        }

        if requiresMCPServers(for: prompt) {
            for name in availableNames {
                let lowerName = name.lowercased()
                if lowerName.contains("mcp") || lowerName.contains("xcode")
                    || lowerName.contains("build_macos") || lowerName.contains("test_macos")
                    || lowerName.contains("swift_package") {
                    selected.insert(name)
                }
            }
        }

        // 4. Always ensure core coordination tools are available if no specific pack matched
        // or alongside domain tools so the supervisor can delegate if needed.
        if selected.isEmpty {
            selected.formUnion(coordinationPack)
            selected.insert("get_system_info")
            selected.insert("read_file")
            selected.insert("list_directory")
            selected.insert("run_shell_command")
            selected.insert("web_search")
            selected.insert("search_memory")
        }

        return availableNames.filter { selected.contains($0) }
    }
}
