import XCTest

@MainActor
final class MultiBotWorkflowsUITests: XCTestCase {

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

    func testSwitchingBetweenBotsUpdatesHeaderAndActiveState() throws {
        launchFreshApp()

        try UITestActivity.step("1. Select Code Architect bot in sidebar") { _ in
            let codeArchitectBot = app.buttons["botSidebarItem_Code Architect"].firstMatch
            XCTAssertTrue(codeArchitectBot.waitForExistence(timeout: 5), "Code Architect button must exist in sidebar")
            codeArchitectBot.click()
            let headerText = app.staticTexts["Code Architect"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must display 'Code Architect'")
        }

        try UITestActivity.step("2. Select Researcher bot in sidebar") { _ in
            let researcherBot = app.buttons["botSidebarItem_Researcher"].firstMatch
            XCTAssertTrue(researcherBot.waitForExistence(timeout: 5), "Researcher button must exist in sidebar")
            researcherBot.click()
            let headerText = app.staticTexts["Researcher"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must switch to 'Researcher'")
        }

        try UITestActivity.step("3. Return to Apex default bot") { _ in
            let apexBot = app.buttons["botSidebarItem_Apex"].firstMatch
            XCTAssertTrue(apexBot.waitForExistence(timeout: 5), "Apex button must exist in sidebar")
            apexBot.click()
            let headerText = app.staticTexts["Apex"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must return to 'Apex'")
        }
    }

    func testCreateBotSheetValidationAndDismissal() throws {
        launchFreshApp()

        try UITestActivity.step("1. Open Create Bot Sheet") { _ in
            let createBtn = app.buttons["createBotButton"].firstMatch
            let sidebarNewBot = app.buttons["New Bot"].firstMatch
            let buttonToClick = createBtn.waitForExistence(timeout: 5) ? createBtn : sidebarNewBot
            XCTAssertTrue(buttonToClick.waitForExistence(timeout: 5), "Create Bot button should appear in UI")
            buttonToClick.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Create Bot sheet should appear")
        }

        try UITestActivity.step("2. Validate bot name input") { _ in
            let nameField = app.textFields["botNameTextField"].firstMatch
            XCTAssertTrue(nameField.waitForExistence(timeout: 3))
            nameField.click()
            nameField.typeText("DevSecOps Bot")
        }

        try UITestActivity.step("3. Dismiss or save sheet") { _ in
            let cancelBtn = app.buttons["Cancel"].firstMatch
            if cancelBtn.waitForExistence(timeout: 2) {
                cancelBtn.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Sheet must dismiss cleanly")
        }
    }
}
