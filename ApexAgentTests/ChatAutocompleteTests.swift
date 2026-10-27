import XCTest
@testable import ApexAgentCore

final class ChatAutocompleteTests: XCTestCase {

    let bots = ["Researcher", "Apex", "Automator", "Code Architect", "Chief of Staff"]
    let commands = BuiltinSlashCommandName.allCases.map { $0.rawValue }

    func testMentionTriggerAppearsForAt() {
        XCTAssertTrue(ChatAutocomplete.isActiveTrigger(in: "@"))
        let items = ChatAutocomplete.mentionSuggestions(botNames: bots, query: "")
        XCTAssertEqual(items.count, 5)
    }

    func testCommandTriggerAppearsForSlash() {
        XCTAssertTrue(ChatAutocomplete.isActiveTrigger(in: "/"))
        let items = ChatAutocomplete.commandSuggestions(commands: commands, query: "")
        XCTAssertEqual(items.count, commands.count)
    }

    func testSelectingMentionInsertsHandle() {
        let result = ChatAutocomplete.applyInsertion("@code-architect", to: "@")
        XCTAssertTrue(result.contains("@code-architect"))
    }

    func testSelectingCommandInsertsCommand() {
        let result = ChatAutocomplete.applyInsertion("/plan", to: "/")
        XCTAssertTrue(result.contains("/plan"))
    }

    func testFilteringNarrowsMentions() {
        let items = ChatAutocomplete.mentionSuggestions(botNames: bots, query: "res")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.display, "Researcher")
    }

    func testFilteringNarrowsCommands() {
        let items = ChatAutocomplete.commandSuggestions(commands: commands, query: "pl")
        XCTAssertTrue(items.contains { $0.display == "plan" })
        XCTAssertTrue(items.allSatisfy { $0.display.localizedCaseInsensitiveContains("pl") })
    }

    func testMidWordAtDoesNotTrigger() {
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "foo@bar"))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "hello@"))
    }

    func testMidWordSlashDoesNotTrigger() {
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "foo/bar"))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "a/b"))
    }

    func testDeletingTriggerCloses() {
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: ""))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "hi "))
    }
}