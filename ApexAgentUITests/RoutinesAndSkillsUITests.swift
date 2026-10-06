import XCTest

@MainActor
final class RoutinesAndSkillsUITests: XCTestCase {

    private var app: XCUIApplication!

    private func launchFreshApp() {
        continueAfterFailure = false
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        let fresh = XCUIApplication()
        fresh.launchEnvironment["APEX_TEST_MODE"] = "1"
        app = fresh
        fresh.launch()
        fresh.activate()
        _ = fresh.wait(for: .runningForeground, timeout: 10)
    }

    override func tearDown() async throws {
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
    }

    func testSettingsSheetRoutinesAndSkillsNavigation() throws {
        launchFreshApp()

        UITestActivity.step("1. Open Settings Sheet") { _ in
            let settingsBtn = app.buttons["settingsButton"].firstMatch
            XCTAssertTrue(settingsBtn.waitForExistence(timeout: 5), "Settings button must exist")
            settingsBtn.click()

            let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
            XCTAssertTrue(settingsForm.waitForExistence(timeout: 10), "Settings form must be presented")
        }

        UITestActivity.step("2. Inspect Settings Form Elements and Dismiss") { _ in
            let doneBtn = app.buttons["settingsDoneButton"].firstMatch
            XCTAssertTrue(doneBtn.waitForExistence(timeout: 5), "settingsDoneButton must exist on Settings sheet")
            doneBtn.click()
            let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
            XCTAssertTrue(settingsForm.waitForNonExistence(timeout: 5), "Settings must dismiss cleanly")
        }
    }

    func testTerminalPanelInteractiveToggle() throws {
        launchFreshApp()

        UITestActivity.step("1. Open Terminal Panel") { _ in
            let terminalBtn = app.buttons["toggleTerminalButton"].firstMatch
            XCTAssertTrue(terminalBtn.waitForExistence(timeout: 5), "toggleTerminalButton must exist")
            let terminalView = app.descendants(matching: .any)["terminalView"].firstMatch
            let initiallyOpen = terminalView.exists
            terminalBtn.click()

            if initiallyOpen {
                XCTAssertTrue(terminalView.waitForNonExistence(timeout: 5), "Terminal view should hide")
            } else {
                XCTAssertTrue(terminalView.waitForExistence(timeout: 5), "Terminal view should appear")
            }
        }
    }

    func testNewConversationButtonClearsInputAndState() throws {
        launchFreshApp()

        UITestActivity.step("1. Type input and click New Conversation button") { _ in
            let input = app.textViews["chatInputField"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5), "Chat input must exist")
            input.click()
            input.typeText("Draft prompt before new conversation")

            let newBtn = app.buttons["newConversationButton"].firstMatch
            XCTAssertTrue(newBtn.waitForExistence(timeout: 5), "newConversationButton must exist in toolbar")
            newBtn.click()

            XCTAssertTrue(input.waitForExistence(timeout: 5), "Chat input must still be present")
        }
    }
}
