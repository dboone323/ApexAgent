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

    func testApplyInsertionUpdatesInputTextCorrectly() {
        // Selection of a bot mention suggestion in multi-word prompt
        let initialText = "Can you ask @res"
        let suggestions = ChatAutocomplete.mentionSuggestions(botNames: bots, query: "res")
        guard let suggestion = suggestions.first else {
            XCTFail("Expected mention suggestion for 'res'")
            return
        }
        let updatedText = ChatAutocomplete.applyInsertion(suggestion.insertion, to: initialText)
        XCTAssertEqual(updatedText, "Can you ask @researcher ")

        // Selection of a command suggestion
        let initialCommandText = "Let us run /diag"
        let cmdSuggestions = ChatAutocomplete.commandSuggestions(commands: commands, query: "diag")
        guard let cmdSuggestion = cmdSuggestions.first else {
            XCTFail("Expected command suggestion for 'diag'")
            return
        }
        let updatedCmdText = ChatAutocomplete.applyInsertion(cmdSuggestion.insertion, to: initialCommandText)
        XCTAssertEqual(updatedCmdText, "Let us run /diagnostics ")
    }

    func testAutocompleteStateClearsOnEmptyOrNonTriggerToken() {
        // Empty text
        XCTAssertNil(ChatAutocomplete.currentToken(in: ""))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: ""))

        // Trailing whitespace indicates finished token
        XCTAssertNil(ChatAutocomplete.currentToken(in: "hello world "))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "hello world "))
        XCTAssertNil(ChatAutocomplete.currentToken(in: "@researcher "))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "@researcher "))

        // Plain text token without trigger prefix
        let nonTriggerToken = ChatAutocomplete.currentToken(in: "search")
        XCTAssertEqual(nonTriggerToken, "search")
        XCTAssertNil(ChatAutocomplete.trigger(for: nonTriggerToken ?? ""))
        XCTAssertFalse(ChatAutocomplete.isActiveTrigger(in: "search"))
    }
}
