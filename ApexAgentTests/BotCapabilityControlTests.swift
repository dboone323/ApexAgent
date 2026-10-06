import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Workstream 3: Bot Capability Controls Tests

@Suite("BotCapabilityControlTests")
struct BotCapabilityControlTests {

    @Test func presetsContainExpectedTools() {
        // Read-only preset should include safe retrieval and inspection tools
        #expect(BotCapabilityPresets.readOnlyTools.contains("read_file"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("list_directory"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("file_search"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("web_search"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("fetch_web_content"))
        #expect(BotCapabilityPresets.readOnlyTools.contains("search_memory"))
        #expect(!BotCapabilityPresets.readOnlyTools.contains("run_shell_command"))
        #expect(!BotCapabilityPresets.readOnlyTools.contains("write_file"))

        // Developer preset should include mutating filesystem, git, and shell tools
        #expect(BotCapabilityPresets.developerTools.contains("read_file"))
        #expect(BotCapabilityPresets.developerTools.contains("write_file"))
        #expect(BotCapabilityPresets.developerTools.contains("patch_file"))
        #expect(BotCapabilityPresets.developerTools.contains("git_operation"))
        #expect(BotCapabilityPresets.developerTools.contains("run_shell_command"))
    }

    @Test func categoryToolCoverage() {
        let categories = BotCapabilityPresets.categories
        #expect(categories.count >= 5)

        let categoryIDs = Set(categories.map { $0.id })
        #expect(categoryIDs.contains("fs_code"))
        #expect(categoryIDs.contains("system_shell"))
        #expect(categoryIDs.contains("web_search"))
        #expect(categoryIDs.contains("memory_plan"))
        #expect(categoryIDs.contains("collaboration"))

        let allTools = categories.flatMap { $0.toolNames }
        #expect(allTools.contains("read_file"))
        #expect(allTools.contains("run_shell_command"))
        #expect(allTools.contains("web_search"))
        #expect(allTools.contains("search_memory"))
        #expect(allTools.contains("ask_bot"))
    }

    @MainActor
    @Test func botCapabilityAllowlistConfiguration() {
        let bot = BotProfile(name: "AuditBot", title: "Security")
        #expect(bot.allowedToolNames.isEmpty) // Unrestricted by default
        #expect(bot.allowedMCPServers.isEmpty)

        bot.allowedToolNames = Array(BotCapabilityPresets.readOnlyTools)
        bot.allowedMCPServers = ["SecurityServer"]

        #expect(bot.allowedToolNames.contains("read_file"))
        #expect(!bot.allowedToolNames.contains("run_shell_command"))
        #expect(bot.allowedMCPServers == ["SecurityServer"])
    }
}
