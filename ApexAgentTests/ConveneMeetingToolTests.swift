import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 4: ConveneMeetingTool Tests", .serialized)
struct ConveneMeetingToolTests {

    @Test("ConveneMeetingTool metadata check")
    @MainActor
    func testConveneMeetingToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = ConveneMeetingTool(orchestrator: orchestrator)
        #expect(tool.name == "convene_meeting")
        #expect(tool.description.contains("Convenes a panel meeting/debate"))
    }

    @Test("ConveneMeetingTool arguments decoding: string array format")
    func testArgumentsDecodingArray() throws {
        let json = """
        {
            "topic": "Architecture Refactoring",
            "participants": ["developer", "researcher"]
        }
        """.data(using: .utf8)!

        let args = try JSONDecoder().decode(ConveneMeetingTool.Arguments.self, from: json)
        #expect(args.topic == "Architecture Refactoring")
        #expect(args.participants == ["developer", "researcher"])
    }

    @Test("ConveneMeetingTool arguments decoding: JSON-encoded array string format")
    func testArgumentsDecodingJSONString() throws {
        let json = """
        {
            "topic": "Security Hardening",
            "participants": "[\\"developer\\", \\"linter\\"]"
        }
        """.data(using: .utf8)!

        let args = try JSONDecoder().decode(ConveneMeetingTool.Arguments.self, from: json)
        #expect(args.topic == "Security Hardening")
        #expect(args.participants == ["developer", "linter"])
    }

    @Test("ConveneMeetingTool arguments decoding: comma-separated string format")
    func testArgumentsDecodingCommaSeparatedString() throws {
        let json = """
        {
            "topic": "UI Redesign",
            "participants": "developer, uiDesigner, planner"
        }
        """.data(using: .utf8)!

        let args = try JSONDecoder().decode(ConveneMeetingTool.Arguments.self, from: json)
        #expect(args.topic == "UI Redesign")
        #expect(args.participants == ["developer", "uiDesigner", "planner"])
    }

    @Test("ConveneMeetingTool returns error when no valid participants exist in registry")
    @MainActor
    func testNoValidParticipants() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = ConveneMeetingTool(orchestrator: orchestrator)

        let args = ConveneMeetingTool.Arguments(
            topic: "Empty Meeting",
            participants: ["fake_bot_one", "fake_bot_two"]
        )
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: No valid participants found in registry."))
    }
}
