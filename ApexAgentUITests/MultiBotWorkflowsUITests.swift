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

    func testSwitchingBetweenBotsUpdatesHeaderAndActiveState() throws {
        launchFreshApp()

        UITestActivity.step("1. Select Code Architect bot in sidebar") { _ in
            let codeArchitectBot = app.buttons["botSidebarItem_Code Architect"].firstMatch
            XCTAssertTrue(codeArchitectBot.waitForExistence(timeout: 5), "Code Architect button must exist in sidebar")
            codeArchitectBot.click()
            let headerText = app.staticTexts["Code Architect"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must display 'Code Architect'")
        }

        UITestActivity.step("2. Select Researcher bot in sidebar") { _ in
            let researcherBot = app.buttons["botSidebarItem_Researcher"].firstMatch
            XCTAssertTrue(researcherBot.waitForExistence(timeout: 5), "Researcher button must exist in sidebar")
            researcherBot.click()
            let headerText = app.staticTexts["Researcher"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must switch to 'Researcher'")
        }

        UITestActivity.step("3. Return to Apex default bot") { _ in
            let apexBot = app.buttons["botSidebarItem_Apex"].firstMatch
            XCTAssertTrue(apexBot.waitForExistence(timeout: 5), "Apex button must exist in sidebar")
            apexBot.click()
            let headerText = app.staticTexts["Apex"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must return to 'Apex'")
        }
    }

    func testCreateBotSheetValidationAndDismissal() throws {
        launchFreshApp()

        UITestActivity.step("1. Open Create Bot Sheet") { _ in
            let createBtn = app.buttons["createBotButton"].firstMatch
            XCTAssertTrue(createBtn.waitForExistence(timeout: 5), "Create Bot button should appear in UI")
            createBtn.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Create Bot sheet should appear")
        }

        UITestActivity.step("2. Validate bot name input and button gating") { _ in
            let saveBtn = app.buttons["saveBotButton"].firstMatch
            XCTAssertTrue(saveBtn.waitForExistence(timeout: 3), "Save button must exist in Create Bot sheet")
            XCTAssertFalse(saveBtn.isEnabled, "Save button must be disabled when bot name is empty")

            let nameField = app.textFields["botNameTextField"].firstMatch
            XCTAssertTrue(nameField.waitForExistence(timeout: 3), "botNameTextField must exist")
            nameField.click()
            nameField.typeText("DevSecOps Bot")

            XCTAssertTrue(saveBtn.isEnabled, "Save button must become enabled once bot name is provided")
        }

        UITestActivity.step("3. Dismiss sheet via Cancel button") { _ in
            let cancelBtn = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancelBtn.waitForExistence(timeout: 5), "Cancel button must exist on Create Bot sheet")
            cancelBtn.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Sheet must dismiss cleanly")
        }
    }

    func testCreateBotSheetFullLifecycleAndSidebarSelection() throws {
        launchFreshApp()

        UITestActivity.step("1. Open Create Bot Sheet") { _ in
            let createBtn = app.buttons["createBotButton"].firstMatch
            XCTAssertTrue(createBtn.waitForExistence(timeout: 5), "Create Bot button should appear in UI")
            createBtn.click()
            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Create Bot sheet should appear")
        }

        UITestActivity.step("2. Fill form and click Save button") { _ in
            let saveBtn = app.buttons["saveBotButton"].firstMatch
            XCTAssertTrue(saveBtn.waitForExistence(timeout: 3), "Save button must exist")
            XCTAssertFalse(saveBtn.isEnabled, "Save button must be disabled when empty")

            let nameField = app.textFields["botNameTextField"].firstMatch
            XCTAssertTrue(nameField.waitForExistence(timeout: 3))
            nameField.click()
            nameField.typeText("Security Auditor")

            XCTAssertTrue(saveBtn.isEnabled, "Save button must be enabled")
            saveBtn.click()

            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Create Bot sheet must dismiss after save")
        }

        UITestActivity.step("3. Select newly created bot in sidebar and verify header") { _ in
            let newBotItem = app.buttons["botSidebarItem_Security Auditor"].firstMatch
            XCTAssertTrue(newBotItem.waitForExistence(timeout: 5), "New bot should appear in sidebar")
            newBotItem.click()

            let headerText = app.staticTexts["Security Auditor"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must switch to 'Security Auditor'")
        }
    }

    func testLiveCustomBotAtMentionInteractionAndResponseEvaluation() throws {
        launchFreshApp()

        UITestActivity.step("1. Create a bot named Code Architect") { _ in
            let createBtn = app.buttons["createBotButton"].firstMatch
            XCTAssertTrue(createBtn.waitForExistence(timeout: 5), "Create Bot button should appear in UI")
            createBtn.click()

            let sheet = app.sheets.firstMatch
            XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Create Bot sheet should appear")

            let nameField = app.textFields["botNameTextField"].firstMatch
            XCTAssertTrue(nameField.waitForExistence(timeout: 3))
            nameField.click()
            nameField.typeText("Code Architect")

            let saveBtn = app.buttons["saveBotButton"].firstMatch
            XCTAssertTrue(saveBtn.isEnabled, "Save button must be enabled after name input")
            saveBtn.click()

            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Create Bot sheet must dismiss")
        }

        UITestActivity.step("2. Select the created bot from the sidebar") { _ in
            let botItem = app.buttons["botSidebarItem_Code Architect"].firstMatch
            XCTAssertTrue(botItem.waitForExistence(timeout: 5), "Created bot must appear in sidebar")
            botItem.click()

            let headerText = app.staticTexts["Code Architect"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header must switch to Code Architect")
        }

        UITestActivity.step("3. Verify Bot Chat input bar buttons") { _ in
            let botInput = app.textFields["botChatInputField"].firstMatch
            XCTAssertTrue(botInput.waitForExistence(timeout: 5), "Bot chat input field should exist")

            let botSend = app.buttons["botSendButton"].firstMatch
            XCTAssertTrue(botSend.waitForExistence(timeout: 5), "Bot send button should exist")
            XCTAssertFalse(botSend.isEnabled, "Bot send button should be disabled when empty")

            botInput.click()
            botInput.typeText("@Code Architect In natural language without tools, what is two plus two?")
            XCTAssertTrue(botSend.isEnabled, "Bot send button should be enabled after typing prompt")
            botSend.click()
        }

        UITestActivity.step("4. Verify response happens first and secondly is correct") { _ in
            let agentMessage = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "BotAgentResponse_")).firstMatch
            XCTAssertTrue(agentMessage.waitForExistence(timeout: 60), "First: Response bubble must appear and stream")

            let candidateText = (agentMessage.value as? String) ?? agentMessage.label
            let text = candidateText.lowercased()
            XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Response must not be blank")
            XCTAssertTrue(text.contains("4") || text.contains("four"), "Second: Response must be correct (4 or four); got: \(text)")
        }
    }
}
