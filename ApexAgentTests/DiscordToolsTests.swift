import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 4: DiscordTools Tests", .serialized)
struct DiscordToolsTests {

    // MARK: - DiscordBotTool Tests

    @Test("DiscordBotTool metadata check")
    @MainActor
    func testDiscordBotToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DiscordBotTool(orchestrator: orchestrator)
        #expect(tool.name == "discord_bot")
        #expect(tool.description.contains("Discord"))
    }

    @Test("DiscordBotTool arguments decoding check")
    func testDiscordBotToolArgumentsDecoding() throws {
        let json = """
        {
            "channelId": "123456789012345678",
            "action": "post",
            "message": "Hello from CI"
        }
        """.data(using: .utf8)!

        let args = try JSONDecoder().decode(DiscordBotTool.Arguments.self, from: json)
        #expect(args.channelId == "123456789012345678")
        #expect(args.action == "post")
        #expect(args.message == "Hello from CI")
    }

    @Test("DiscordBotTool returns descriptive error when bot token is not configured")
    @MainActor
    func testDiscordBotToolMissingToken() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DiscordBotTool(orchestrator: orchestrator)

        let args = DiscordBotTool.Arguments(channelId: "1234567890", action: "post", message: "Test")

        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: No bot token configured"))
    }

    // MARK: - DiscordWebhookTool Tests

    @Test("DiscordWebhookTool metadata check")
    @MainActor
    func testDiscordWebhookToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DiscordWebhookTool(orchestrator: orchestrator)
        #expect(tool.name == "discord_webhook")
        #expect(tool.description.contains("webhook"))
    }

    @Test("DiscordWebhookTool arguments decoding check")
    func testDiscordWebhookToolArgumentsDecoding() throws {
        let json = """
        {
            "message": "CI Build Passed",
            "username": "ApexAgentBot",
            "avatarUrl": "https://example.com/avatar.png"
        }
        """.data(using: .utf8)!

        let args = try JSONDecoder().decode(DiscordWebhookTool.Arguments.self, from: json)
        #expect(args.message == "CI Build Passed")
        #expect(args.username == "ApexAgentBot")
        #expect(args.avatarUrl == "https://example.com/avatar.png")
    }

    @Test("DiscordWebhookTool returns descriptive error when webhook URL is not configured")
    @MainActor
    func testDiscordWebhookToolMissingURL() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = DiscordWebhookTool(orchestrator: orchestrator)

        let args = DiscordWebhookTool.Arguments(message: "Test message")

        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: No webhook URL configured"))
    }
}
