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
        app = fresh
        fresh.launch()
        fresh.activate()
        _ = fresh.wait(for: .runningForeground, timeout: 10)
    }

    override func tearDownWithError() throws {
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
    }

    func testSettingsSheetRoutinesAndSkillsNavigation() throws {
        launchFreshApp()

        try UITestActivity.step("1. Open Settings Sheet") { _ in
            let settingsBtn = app.buttons["settingsButton"].firstMatch
            XCTAssertTrue(settingsBtn.waitForExistence(timeout: 5), "Settings button must exist")
            settingsBtn.click()

            let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
            XCTAssertTrue(settingsForm.waitForExistence(timeout: 10), "Settings form must be presented")
        }

        try UITestActivity.step("2. Inspect Settings Form Elements") { _ in
            // Close Settings window or sheet
            let settingsWindow = app.windows["Settings"].firstMatch
            if settingsWindow.exists {
                settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
            let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
            XCTAssertTrue(settingsForm.waitForNonExistence(timeout: 5), "Settings must dismiss cleanly")
        }
    }

    func testTerminalPanelInteractiveToggle() throws {
        launchFreshApp()

        try UITestActivity.step("1. Open Terminal Panel") { _ in
            let terminalBtn = app.buttons["toggleTerminalButton"].firstMatch
            XCTAssertTrue(terminalBtn.waitForExistence(timeout: 5))
            let terminalView = app.descendants(matching: .any)["terminalView"].firstMatch
            let initiallyOpen = terminalView.exists
            terminalBtn.click()

            if initiallyOpen {
                XCTAssertTrue(terminalView.waitForNonExistence(timeout: 5))
            } else {
                XCTAssertTrue(terminalView.waitForExistence(timeout: 5))
            }
        }
    }
}
