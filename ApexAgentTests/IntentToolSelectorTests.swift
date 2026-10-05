import Testing
import Foundation
@testable import ApexAgentCore

@Suite("IntentToolSelector & Audit Fixes Verification Tests")
struct IntentToolSelectorTests {

    @Test("Conversational, math, and conceptual Q&A prompts automatically disable tool calling")
    func testToolFreeIntentDisablesTools() {
        #expect(IntentToolSelector.shouldEnableTools(for: "Hello!") == false)
        #expect(IntentToolSelector.shouldEnableTools(for: "What is 2 + 2?") == false)
        #expect(IntentToolSelector.shouldEnableTools(for: "Calculate 14 * 9") == false)
        #expect(IntentToolSelector.shouldEnableTools(for: "Explain in one sentence why Swift actors prevent data races.") == false)
        #expect(IntentToolSelector.shouldEnableTools(for: "What is the difference between a struct and a class in Swift?") == false)
        #expect(IntentToolSelector.shouldEnableTools(for: "State your #1 priority for Swift 6 concurrency safety in one sentence.") == false)
    }

    @Test("Action prompts and outer orchestration calls enable tools even if inner task says without calling tools")
    func testActionAndOrchestrationPromptsEnableTools() {
        #expect(IntentToolSelector.shouldEnableTools(for: "Call the get_system_info tool and report the CPU model.") == true)
        #expect(IntentToolSelector.shouldEnableTools(for: "Read Package.swift and list the products.") == true)
        #expect(IntentToolSelector.shouldEnableTools(
            for: "@apex change bot names containing TestBot to friendly role-based names"
        ) == true)
        #expect(IntentToolSelector.shouldEnableTools(
            for: "Call delegate_task with agentType 'developer' and taskDescription 'Answer in one sentence without calling any tools: What is your primary responsibility?'"
        ) == true)
        #expect(IntentToolSelector.shouldEnableTools(
            for: "Call dispatch_swarm with targetBots 'Auditor, Critic' and taskPrompts 'Answer without using tools: What is your #1 priority?'"
        ) == true)
    }

    @Test("Domain pack selection scopes tool schemas and excludes heavy MCP tools unless requested")
    func testDomainPackSelectionAndMCPGating() {
        let sampleSchemas: [[String: Any]] = [
            ["name": "get_system_info"],
            ["name": "read_file"],
            ["name": "write_file"],
            ["name": "delegate_task"],
            ["name": "dispatch_swarm"],
            ["name": "convene_meeting"],
            ["name": "xcodebuildmcp_build_macos"],
            ["name": "mcp_filesystem_read"]
        ]

        // Explicit single-tool instruction scopes strictly to that tool
        let explicitTools = IntentToolSelector.selectRelevantToolNames(
            for: "Call the get_system_info tool and report the CPU model in one sentence.",
            allSchemas: sampleSchemas
        )
        #expect(explicitTools == ["get_system_info"])

        // Filesystem prompt selects filesystem pack + coordination pack, excluding MCP tools
        let fsTools = IntentToolSelector.selectRelevantToolNames(
            for: "Read the file Package.swift in the current directory",
            allSchemas: sampleSchemas
        )
        #expect(fsTools.contains("read_file"))
        #expect(!fsTools.contains("xcodebuildmcp_build_macos"))
        #expect(!fsTools.contains("mcp_filesystem_read"))

        // Xcode/MCP prompt includes MCP tools
        let xcodeTools = IntentToolSelector.selectRelevantToolNames(
            for: "Run an xcodebuildmcp build for the project",
            allSchemas: sampleSchemas
        )
        #expect(xcodeTools.contains("xcodebuildmcp_build_macos"))
        #expect(IntentToolSelector.requiresMCPServers(for: "Run an xcodebuildmcp build for the project") == true)
        #expect(IntentToolSelector.requiresMCPServers(for: "Explain in one sentence why Swift actors prevent data races.") == false)
    }

    @Test("OllamaAgentEngine extracts raw JSON tool calls emitted by 7B/8B models")
    @MainActor
    func testExtractFallbackToolCalls() {
        let available: Set<String> = ["get_system_info", "read_file", "delegate_task"]
        let rawContent = """
        I'm gathering system information to find the CPU model for you.
        {"name": "get_system_info", "arguments": {}}
        """
        let extracted = OllamaAgentEngine.extractFallbackToolCalls(from: rawContent, availableToolNames: available)
        #expect(extracted.count == 1)
        let fn = extracted.first?["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "get_system_info")
    }

    @Test("AgentRegistry resolves Critic and Controller includes get_system_info")
    func testAgentRegistryResolutionAndControllerTools() {
        let critic = AgentRegistry.shared.resolve(name: "Critic")
        #expect(critic != nil)
        #expect(critic?.name == "linter")

        let controller = AgentRegistry.shared.resolve(name: "Pilot")
        #expect(controller != nil)
        #expect(controller?.allowedTools.contains("get_system_info") == true)
    }

    @Test("Multi-step connectors include all chained tools and ModelProvider.parse resolves CLI aliases")
    func testMultiStepConnectorAndProviderAliases() {
        let sampleSchemas: [[String: Any]] = [
            ["name": "file_search"],
            ["name": "read_file"],
            ["name": "store_memory"],
            ["name": "search_memory"]
        ]
        let chained = IntentToolSelector.selectRelevantToolNames(
            for: "Call file_search to find IntentToolSelector.swift, then call read_file on that path",
            allSchemas: sampleSchemas
        )
        #expect(chained.contains("file_search"))
        #expect(chained.contains("read_file"))

        #expect(IntentToolSelector.requiresMCPServers(for: "Store memory key 'xcode_27_2_beta_2_toolchain'") == false)
        #expect(IntentToolSelector.requiresMCPServers(for: "Call xcode_ide_list_tools") == true)

        #expect(ModelProvider.parse("appleFoundation") == .appleOnDevice)
        #expect(ModelProvider.parse("localSystem") == .appleOnDevice)
        #expect(ModelProvider.parse("ollamaLocal") == .localOllama)
        #expect(ModelProvider.parse("cloudGemini") == .cloudGemini)
    }

    @Test("Successful shell results require a separate check before reporting completion")
    func testShellResultsRequireVerification() {
        let result = AgentExecutionVerification.applyingToolResultGuidance(
            toolName: "run_shell_command",
            result: "Command completed."
        )
        #expect(result.contains("POST-EXECUTION CHECK REQUIRED"))
        #expect(result.contains("separate read-only tool"))

        #expect(AgentExecutionVerification.applyingToolResultGuidance(
            toolName: "run_shell_command",
            result: "ERROR: command failed"
        ) == "ERROR: command failed")
        #expect(AgentExecutionVerification.applyingToolResultGuidance(
            toolName: "read_file",
            result: "file contents"
        ) == "file contents")
    }

    @Test("Verification policy is included in routed agent instructions")
    func testVerificationDirectiveIsIdempotent() {
        let once = AgentExecutionVerification.applyingDirective(to: "Bot persona")
        let twice = AgentExecutionVerification.applyingDirective(to: once)
        #expect(once.contains("EXECUTION VERIFICATION"))
        #expect(once.contains("Never invent tool names"))
        #expect(twice == once)
    }
}
