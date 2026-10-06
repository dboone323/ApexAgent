import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - P1-2: Team Playbook

@Suite("TeamPlaybookTests")
struct TeamPlaybookTests {

    @Test func jsonRoundTrip() throws {
        let playbook = TeamPlaybook(
            name: "Dev Team",
            description: "A development team",
            bots: [
                PlaybookBot(
                    name: "Coder",
                    title: "Developer",
                    description: "Writes Swift code",
                    avatarName: "hammer.fill",
                    isChiefOfStaff: false,
                    modelProvider: "localOllama",
                    ollamaModel: "qwen2.5-coder:32b"
                ),
                PlaybookBot(
                    name: "Lead",
                    title: "Chief of Staff",
                    description: "Coordinates the team",
                    avatarName: "person.3.fill",
                    isChiefOfStaff: true
                )
            ]
        )

        let data = try playbook.encode()
        let decoded = try TeamPlaybook.decode(from: data)

        #expect(decoded.name == "Dev Team")
        #expect(decoded.description == "A development team")
        #expect(decoded.version == "1.0")
        #expect(decoded.bots.count == 2)
        #expect(decoded.bots[0].name == "Coder")
        #expect(decoded.bots[0].modelProvider == "localOllama")
        #expect(decoded.bots[0].ollamaModel == "qwen2.5-coder:32b")
        #expect(decoded.bots[1].name == "Lead")
        #expect(decoded.bots[1].isChiefOfStaff == true)
        #expect(decoded.bots[1].modelProvider == nil)
    }

    @Test func markdownRoundTrip() throws {
        let playbook = TeamPlaybook(
            name: "Support Team",
            description: "Customer support bots",
            bots: [
                PlaybookBot(
                    name: "Triage",
                    title: "Support Triage",
                    description: "Routes tickets",
                    avatarName: "tray.full.fill",
                    isChiefOfStaff: false,
                    modelProvider: "appleOnDevice"
                ),
                PlaybookBot(
                    name: "Escalation",
                    title: "Escalation Manager",
                    description: "Handles escalated issues",
                    avatarName: "exclamationmark.triangle.fill",
                    isChiefOfStaff: true,
                    memory: "Always CC the VP on P0s"
                )
            ]
        )

        let markdown = playbook.toMarkdown()
        let decoded = try TeamPlaybook.decodeFromMarkdown(markdown)

        #expect(decoded.name == "Support Team")
        #expect(decoded.description == "Customer support bots")
        #expect(decoded.bots.count == 2)
        #expect(decoded.bots[0].name == "Triage")
        #expect(decoded.bots[0].modelProvider == "appleOnDevice")
        #expect(decoded.bots[1].name == "Escalation")
        #expect(decoded.bots[1].isChiefOfStaff == true)
        #expect(decoded.bots[1].memory?.contains("Always CC the VP") == true)
    }

    @Test func markdownFormatContainsFrontmatter() {
        let playbook = TeamPlaybook(
            name: "Test",
            description: "A test playbook",
            bots: [
                PlaybookBot(name: "Bot", title: "Helper", description: "Helps",
                            avatarName: "person.fill", isChiefOfStaff: false)
            ]
        )
        let md = playbook.toMarkdown()
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("name: \"Test\""))
        #expect(md.contains("## Bot: Bot"))
    }

    @Test func decodeFromMarkdownRejectsInvalidFormat() {
        let invalid = "No frontmatter here\nJust plain text"
        #expect(throws: TeamPlaybook.PlaybookError.self) {
            try TeamPlaybook.decodeFromMarkdown(invalid)
        }
    }

    @Test func emptyPlaybookEncodesAndDecodes() throws {
        let playbook = TeamPlaybook(name: "Empty", description: "No bots", bots: [])
        let data = try playbook.encode()
        let decoded = try TeamPlaybook.decode(from: data)
        #expect(decoded.bots.isEmpty)
        #expect(decoded.name == "Empty")
    }
}
