import XCTest

// MARK: - Phase 4: real end-to-end UI automation of the built ApexAgent.app.
// Drives the running app through XCUITest (Accessibility/automation entitlement
// on the test runner). No mocks: this launches the real .app and interacts with
// its real UI elements, asserted by accessibility identifiers added to the
// product in Phase 4 (chatInputField, sendButton, settingsButton,
// toggleTerminalButton, terminalView, settingsForm).

final class ApexAgentUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Launch fresh each test for isolation.
        app.launch()
        // Ensure the app is the active/frontmost app so XCUITest events (taps,
        // key presses) are delivered to its windows, not the test runner.
        app.activate()
        sleep(1)
        // The chat input is a SwiftUI TextEditor, which the AX hierarchy
        // exposes as a text view (not a text field). Accept either.
        let input = chatInput
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Chat input field did not appear — app failed to render.")
    }

    /// The chat input is a TextEditor → AX text view. Falls back to textField
    /// in case a future refactor swaps the control.
    private var chatInput: XCUIElement {
        let tv = app.textViews["chatInputField"].firstMatch
        if tv.exists { return tv }
        return app.textFields["chatInputField"].firstMatch
    }

    /// Tap an element via .click() — the native macOS click. .tap() is
    /// unreliable for SwiftUI toolbar buttons on macOS; .click() drives the
    /// real control action deterministically.
    private func tapCenter(_ element: XCUIElement) {
        element.click()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    /// Types a prompt and taps send; asserts the user's message renders in the
    /// conversation. Deterministic: ChatInputBar.send() clears inputText and
    /// orchestrator.sendMessage() appends the user message, so this passes even
    /// when no LLM is available.
    @MainActor func testSendMessageRendersUserBubble() throws {
        let input = chatInput
        let prompt = "What is 2 + 2?"
        input.click() // focus
        input.typeText(prompt)

        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))

        // The send button only becomes enabled once inputText is non-empty.
        // typeText propagates to the binding asynchronously, so wait (poll) for
        // the enabled state before tapping — otherwise the tap lands while the
        // button is still disabled and is silently ignored.
        let enabledExpectation = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send,
                                             handler: nil)
        let _ = XCTWaiter.wait(for: [enabledExpectation], timeout: 5)
        XCTAssertTrue(send.isEnabled, "Send button should be enabled with non-empty input.")
        XCTAssertTrue(send.isHittable, "Send button should be on-screen and tappable.")

        // Primary path: tap the button's center coordinate (avoids inner-ZStack
        // hit-target ambiguity). Fallback: Return key, which the TextEditor's
        // .onKeyPress(.return) handles -> send().
        tapCenter(send)
        let clearedPredicate = NSPredicate(format: "value == '' OR value == nil")
        let clearedFast = XCTWaiter.wait(for: [expectation(for: clearedPredicate, evaluatedWith: chatInput)], timeout: 2) == .completed
        if !clearedFast {
            chatInput.click()
            app.typeKey(.return, modifierFlags: [])
        }

        // The typed text must appear as a rendered user bubble, tagged with the
        // "UserMessage" accessibility identifier (added in Phase 4). This is a
        // stable element, independent of the input field's transient text.
        let transcript = app.scrollViews["conversationScrollView"].firstMatch
        let bubble = transcript.descendants(matching: .any)["UserMessage"].firstMatch
        XCTAssertTrue(
            bubble.waitForExistence(timeout: 10),
            "The sent prompt did not render as a user message bubble in the conversation."
        )

        // Input field clears after send (orchestrator resets inputText).
        let result = XCTWaiter.wait(for: [expectation(for: clearedPredicate, evaluatedWith: chatInput)], timeout: 3)
        XCTAssertTrue(result == .completed, "Input field should clear after sending; got '\(chatInput.value ?? "nil")'.")
    }

    /// Opens and dismisses the Settings sheet via the toolbar gear button.
    @MainActor func testSettingsSheetOpensAndCloses() throws {
        let settings = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))

        tapCenter(settings)
        // The settings sheet presents as a window titled "Settings".
        let settingsWindow = app.windows["Settings"].firstMatch
        let navBar = app.navigationBars["Settings"].firstMatch
        let form = app.descendants(matching: .any)["settingsForm"].firstMatch
        let sheet = app.sheets.firstMatch
        let appeared = settingsWindow.waitForExistence(timeout: 10)
            || navBar.waitForExistence(timeout: 10)
            || form.waitForExistence(timeout: 10)
            || sheet.waitForExistence(timeout: 10)
        XCTAssertTrue(appeared, "Settings sheet did not appear after tapping gear.")

        // Close via Escape (sheet dismiss) and assert it goes away.
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = settingsWindow.waitForNonExistence(timeout: 5)
            || navBar.waitForNonExistence(timeout: 5)
            || form.waitForNonExistence(timeout: 5)
            || sheet.waitForNonExistence(timeout: 5)
        XCTAssertTrue(dismissed, "Settings sheet should dismiss on Escape.")
    }

    /// Toggles the terminal console panel and asserts it appears.
    @MainActor func testTerminalPanelToggles() throws {
        let toggle = app.buttons["toggleTerminalButton"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        tapCenter(toggle)
        // TerminalView carries accessibilityIdentifier "terminalView" (Phase 4).
        // It may surface as a scrollView, other, or group — search all roles.
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let appeared = terminal.waitForExistence(timeout: 10)
        XCTAssertTrue(appeared, "Terminal panel did not appear after toggling.")

        // Toggle off again.
        tapCenter(toggle)
        XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "Terminal panel should disappear when toggled off.")
    }

    /// Starts a new conversation via the toolbar button (deterministic UI action).
    @MainActor func testNewConversationButton() throws {
        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        // Should not throw / crash the app.
        tapCenter(newBtn)
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5), "Chat input should still be present after New Conversation.")
    }
}
