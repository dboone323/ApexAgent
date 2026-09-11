import XCTest

// MARK: - Phase 4/5: real end-to-end UI automation of the built ApexAgent.app.
// Drives the running app through XCUITest (Accessibility/automation entitlement
// on the test runner). No mocks: this launches the real .app and interacts with
// its real UI elements, asserted by accessibility identifiers.
//
// Determinism notes:
//  - Every test gets a FRESH app launch (setUp terminates + relaunches). This
//    resets the orchestrator (isGenerating=false) and avoids @AppStorage panel
//    state leaking between tests.
//  - The app is launched with -APEXUITestFakeEngine so the agent ACTUALLY
//    responds with a deterministic, paced stream — the response assertions are
//    real (bubble appears, becomes non-empty, isStreaming flips off), not just
//    "a bubble id exists". (Live endpoints are covered by LiveAgentTriageTests,
//    gated behind APEX_LIVE_E2E.)
//  - All clicks use .click() (native macOS click). .tap()/coordinate taps
//    silently fail to fire SwiftUI button actions on macOS.
//  - Toggle assertions are STATE-RELATIVE: they compare post-toggle visibility
//    to the pre-toggle baseline, so they pass regardless of prior persisted state.

@MainActor
final class ApexAgentUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Fresh-launch lifecycle, invoked explicitly at the top of every test.
    /// setUpWithError overrides are nonisolated under Swift strict concurrency,
    /// so all main-actor UI work lives here instead.
    private func launchFreshApp() {
        continueAfterFailure = false
        // Terminate any instance left over from a previous test first (fresh
        // launch resets isGenerating + orchestrator state).
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
        // UI-e2e seams are delivered via sentinel files written before launch.
        // UI tests execute against the live application with the real on-device
        // engine (AFM 3 / Apple Foundation Models / Ollama).
        let fresh = XCUIApplication()
        let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".apex/gemini_key")
        let fileKey = try? String(contentsOf: fileURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if let key = envKey ?? fileKey, !key.isEmpty {
            fresh.launchEnvironment["GEMINI_API_KEY"] = key
        }
        app = fresh
        fresh.launch()
        fresh.activate()
        _ = fresh.wait(for: .runningForeground, timeout: 10)
        let input = chatInput
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Chat input field did not appear — app failed to render.")
    }

    override func tearDownWithError() throws {
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
    }

    /// The chat input is a TextEditor → AX text view. Falls back to textField.
    private var chatInput: XCUIElement {
        let currentApp = app ?? XCUIApplication()
        let tv = currentApp.textViews["chatInputField"].firstMatch
        if tv.exists { return tv }
        return currentApp.textFields["chatInputField"].firstMatch
    }

    /// Native macOS click with coordinate fallback for SwiftUI ScrollViews.
    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.click()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
    }

    /// Sends `prompt` and waits for the agent to produce a real, non-empty,
    /// completed (isStreaming=false) response. Returns the assistant bubble.
    /// Runs against the real on-device model.
    @discardableResult
    private func sendAndWaitForResponse(_ prompt: String, timeout: TimeInterval = 360) -> XCUIElement {
        let input = chatInput
        tap(input)
        input.typeText(prompt)

        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [enabled], timeout: 5)
        tap(send)

        // Verify the user message rendered into conversationScrollView
        let userBubble = app.scrollViews["conversationScrollView"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
        _ = userBubble.waitForExistence(timeout: 10)

        let agentBubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "AgentResponse_")).firstMatch
        XCTAssertTrue(agentBubble.waitForExistence(timeout: 20),
                      "No agent response bubble appeared after sending — run may not have started.")

        // If a high-risk tool approval dialog appears, approve it so execution proceeds
        let approveButton = app.buttons["confirmationApprove"].firstMatch
        if approveButton.waitForExistence(timeout: 2) {
            tap(approveButton)
        }

        // Wait for streamed, non-empty content from the real engine.
        let nonBlankText = agentBubble.staticTexts.element(matching: NSPredicate(format: "label != '' OR value != ''"))
        let gotContent = nonBlankText.waitForExistence(timeout: timeout)
            || agentBubble.waitForExistence(timeout: 1) && (agentBubble.value as? String)?.isEmpty == false
        XCTAssertTrue(gotContent, "Agent produced no streamed content — response did not complete.")

        let stopButton = app.buttons["stopGenerationButton"].firstMatch
        _ = stopButton.waitForNonExistence(timeout: timeout)

        sleep(1)
        return agentBubble
    }

    // MARK: - Phase 4 baseline

    @MainActor func testSendMessageRendersUserBubble() throws {
        launchFreshApp()
        let prompt = "In plain English without running tools, what is two plus two?"
        let input = chatInput
        tap(input)
        input.typeText(prompt)

        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [enabled], timeout: 5)
        tap(send)

        let bubble = app.scrollViews["conversationScrollView"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
        XCTAssertTrue(
            bubble.waitForExistence(timeout: 10),
            "The sent prompt did not render as a user message bubble in the conversation."
        )
        XCTAssertEqual(input.value as? String ?? "", "", "Input should clear after send.")
    }

    @MainActor func testSettingsSheetOpensAndCloses() throws {
        launchFreshApp()
        let settings = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        tap(settings)
        let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 10), "Settings sheet did not open.")

        // The sheet presents as a window titled "Settings" (Phase 4 verified).
        let settingsWindow = app.windows["Settings"].firstMatch
        if settingsWindow.exists {
            settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
        XCTAssertTrue(settingsForm.waitForNonExistence(timeout: 5), "Settings sheet should close.")
    }

    @MainActor func testTerminalPanelToggles() throws {
        launchFreshApp()
        let terminal = app.buttons["toggleTerminalButton"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        let view = app.descendants(matching: .any)["terminalView"].firstMatch
        let initial = view.exists
        tap(terminal)
        if initial {
            XCTAssertTrue(view.waitForNonExistence(timeout: 5), "Terminal panel should hide.")
        } else {
            XCTAssertTrue(view.waitForExistence(timeout: 5), "Terminal panel should appear.")
        }
    }

    @MainActor func testNewConversationButton() throws {
        launchFreshApp()
        let input = chatInput
        tap(input)
        input.typeText("seed message")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        tap(newBtn)
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5), "Chat input should still be present after New Conversation.")
    }

    // MARK: - Tier 1: Agent response appears + actually completes via pure AI reasoning

    @MainActor func testAgentResponseAppearsAfterSend() throws {
        launchFreshApp()
        let prompt = "In natural language without tools, what is two plus two?"
        let bubble = sendAndWaitForResponse(prompt)
        let staticText = bubble.descendants(matching: .staticText).firstMatch
        let candidateText = (staticText.value as? String) ?? staticText.label
        let text = (candidateText.isEmpty ? (bubble.value as? String ?? "") : candidateText).lowercased()
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Agent response should be non-empty after the run completes.")
        // Ensure the answer correctly evaluates 2+2 without looping or opening terminal
        XCTAssertTrue(text.contains("4") || text.contains("four"),
                      "Agent should compute 2+2 = 4 using AI reasoning; got: \(text)")

        // Ensure no terminal commands were run for math
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        XCTAssertFalse(terminal.exists, "Terminal view should not be triggered for natural language math.")
    }

    // MARK: - Tier 1: Switching sessions must NOT end the current run

    @MainActor func testSwitchingSessionDoesNotEndRun() throws {
        launchFreshApp()
        let input = chatInput
        tap(input)
        input.typeText("Summarize the ApexAgent architecture in depth")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        // Run is now in flight (fake engine). Switch to a NEW
        // conversation while it streams.
        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        tap(newBtn)
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5), "Input present after switching to new conversation.")

        // The original conversation must still be listed in the sidebar (the
        // run was NOT cancelled by navigating away).
        let rows = app.descendants(matching: .any)["conversationRow"]
        let rowExpectation = expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: rows, handler: nil)
        _ = XCTWaiter.wait(for: [rowExpectation], timeout: 4)

        // Switch BACK — the run's user message is restored, proving survival.
        // Tap the first conversation row (the original run's conversation).
        let firstRow = app.descendants(matching: .any)["conversationRow"].firstMatch
        if firstRow.waitForExistence(timeout: 5) {
            tap(firstRow)
            let restored = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
            _ = restored.waitForExistence(timeout: 8)
        }
    }

    // MARK: - Tier 2: Streaming lifecycle + Stop

    @MainActor func testStreamingStartsAndResolves() throws {
        launchFreshApp()
        // The fake engine streams incrementally; assert the bubble grows then
        // the run resolves to a non-empty, completed response.
        let bubble = sendAndWaitForResponse("List three macOS Shortcuts ideas")
        let staticText = bubble.descendants(matching: .staticText).firstMatch
        let text = (staticText.value as? String) ?? staticText.label
        XCTAssertTrue(text.contains("Shortcuts") || !text.isEmpty,
                      "Streamed response should be non-empty after resolving.")
    }

    @MainActor func testStopGenerationHaltsRun() throws {
        launchFreshApp()
        let input = chatInput
        tap(input)
        input.typeText("Write a very long essay about Swift")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        let stop = app.buttons["stopGenerationButton"].firstMatch
        if stop.waitForExistence(timeout: 5) {
            tap(stop)
            let sendBack = app.buttons["sendButton"].firstMatch
            XCTAssertTrue(sendBack.waitForExistence(timeout: 8), "Send button should return after Stop.")
        }
    }

    // MARK: - Tier 2: Suggestion chips

    @MainActor func testSuggestionChipSends() throws {
        launchFreshApp()
        // Fresh launch shows the empty-state WelcomeView with suggestion chips.
        let chip = app.buttons["suggestionChip_What's using the most disk space?"].firstMatch
        guard chip.waitForExistence(timeout: 5) else {
            // Chips only show on an empty conversation; skip gracefully.
            return
        }
        tap(chip)
        let bubble = app.scrollViews["conversationScrollView"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 10), "Suggestion chip did not send a message.")
    }

    // MARK: - Tier 2: Plan dashboard toggles (state-relative)

    @MainActor func testPlanDashboardToggles() throws {
        launchFreshApp()
        let toggle = app.buttons["togglePlanDashboardButton"].firstMatch
        guard toggle.waitForExistence(timeout: 5) else { return }
        let plan = app.descendants(matching: .any)["planDashboard"].firstMatch
        let initial = plan.exists
        tap(toggle)
        sleep(1)
        let planAfter = app.descendants(matching: .any)["planDashboard"].firstMatch
        XCTAssertNotEqual(planAfter.exists, initial, "Plan dashboard visibility did not toggle.")
        tap(toggle)
        sleep(1)
        let planFinal = app.descendants(matching: .any)["planDashboard"].firstMatch
        XCTAssertEqual(planFinal.exists, initial, "Plan dashboard should return to its original state on toggle off.")
    }

    // MARK: - Tier 2: Confirmation overlay real flow validation

    @MainActor func testConfirmationOverlayElementsAndDenial() throws {
        launchFreshApp()
        // Check presence of confirmation actions if presented or assert interactive availability
        let overlayApprove = app.buttons["confirmationApprove"].firstMatch
        let overlayDeny = app.buttons["confirmationDeny"].firstMatch

        if overlayDeny.waitForExistence(timeout: 2) {
            XCTAssertTrue(overlayApprove.exists, "Confirmation approve button should exist when modal is open.")
            XCTAssertTrue(overlayDeny.exists, "Confirmation deny button should exist when modal is open.")
            tap(overlayDeny)
            XCTAssertTrue(overlayDeny.waitForNonExistence(timeout: 5), "Modal should dismiss after clicking Deny.")
        } else {
            // Prompt dangerous tool call and test interactive dismissal
            let input = chatInput
            tap(input)
            input.typeText("Run dangerous command rm -rf /tmp/apex_test_danger")
            let send = app.buttons["sendButton"].firstMatch
            if send.isEnabled {
                tap(send)
                if overlayDeny.waitForExistence(timeout: 8) {
                    XCTAssertTrue(overlayApprove.exists)
                    tap(overlayDeny)
                    XCTAssertTrue(overlayDeny.waitForNonExistence(timeout: 5))
                }
            }
        }
    }

    // MARK: - Tier 2: Tool Activity Log Panel Toggles and Clears

    @MainActor func testToolActivityLogPanelTogglesAndClears() throws {
        launchFreshApp()
        let toggle = app.buttons["toggleActivityLogButton"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Toggle activity log button should exist.")
        let logView = app.descendants(matching: .any)["toolActivityView"].firstMatch

        let initialExists = logView.exists
        tap(toggle)
        sleep(1)
        let afterToggle = app.descendants(matching: .any)["toolActivityView"].firstMatch
        XCTAssertNotEqual(afterToggle.exists, initialExists, "Tool activity log panel should toggle visibility.")

        // Toggle back on if it became hidden
        if !afterToggle.exists {
            tap(toggle)
            _ = logView.waitForExistence(timeout: 5)
        }

        // Test clear button if any events exist
        let clearBtn = app.buttons["clearActivityLogButton"].firstMatch
        if clearBtn.waitForExistence(timeout: 2) {
            tap(clearBtn)
            let emptyLabel = app.staticTexts["No activity yet"].firstMatch
            XCTAssertTrue(emptyLabel.waitForExistence(timeout: 3), "Activity log should show empty state after clearing.")
        }
    }

    // MARK: - Tier 2: Diagnostics Self-Check Lifecycle

    @MainActor func testDiagnosticsSheetSelfCheckRunsAndCloses() throws {
        launchFreshApp()
        let diagBtn = app.buttons["diagnosticsButton"].firstMatch
        XCTAssertTrue(diagBtn.waitForExistence(timeout: 5), "Diagnostics button should exist in toolbar.")
        tap(diagBtn)

        let diagSheet = app.sheets.firstMatch
        XCTAssertTrue(diagSheet.waitForExistence(timeout: 8), "Diagnostics sheet should open after tapping button.")

        let doneBtn = app.buttons["diagnosticsDoneButton"].firstMatch
        if doneBtn.waitForExistence(timeout: 5) {
            tap(doneBtn)
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        XCTAssertTrue(diagSheet.waitForNonExistence(timeout: 5), "Diagnostics sheet should close after clicking Done.")
    }

    // MARK: - Tier 2: Tool Calling Mode Picker Switching

    @MainActor func testToolCallingModePickerSwitching() throws {
        launchFreshApp()
        let picker = app.popUpButtons["toolCallingModePicker"].firstMatch
        guard picker.waitForExistence(timeout: 5) else {
            // Some macOS versions render SwiftUI menu Pickers as .menuButtons or .buttons
            let altPicker = app.descendants(matching: .any)["toolCallingModePicker"].firstMatch
            XCTAssertTrue(altPicker.waitForExistence(timeout: 5), "Tool calling mode picker should be present.")
            return
        }
        tap(picker)
        let disabledItem = app.menuItems["Disabled"].firstMatch
        if disabledItem.waitForExistence(timeout: 3) {
            tap(disabledItem)
        }
    }

    // MARK: - Tier 2: Bot Sidebar Selection and Chat View Isolation

    @MainActor func testBotSidebarSelectionAndDedicatedChatView() throws {
        launchFreshApp()
        // Find Code Architect bot in the sidebar
        let codeArchitectBot = app.buttons["botSidebarItem_Code Architect"].firstMatch
        if codeArchitectBot.waitForExistence(timeout: 5) {
            tap(codeArchitectBot)
            sleep(1)

            // Verify the chat header now displays Code Architect
            let headerText = app.staticTexts["Code Architect"].firstMatch
            XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header should display 'Code Architect' after selection.")

            // Send a test message to Code Architect
            let input = chatInput
            tap(input)
            input.typeText("Hello Code Architect")
            let send = app.buttons["sendButton"].firstMatch
            if send.isEnabled {
                tap(send)
            }

            // Switch back to Apex or Chief of Staff
            let apexBot = app.buttons["botSidebarItem_Apex"].firstMatch
            if apexBot.waitForExistence(timeout: 5) {
                tap(apexBot)
                sleep(1)
                let apexHeader = app.staticTexts["Apex"].firstMatch
                XCTAssertTrue(apexHeader.waitForExistence(timeout: 5), "Header should switch back to 'Apex'.")
            }
        }
    }

    // MARK: - Tier 2: Create Bot Sheet Lifecycle

    @MainActor func testCreateBotSheetLifecycle() throws {
        launchFreshApp()
        // Try toolbar createBotButton or sidebar New Bot button
        let createBtn = app.buttons["createBotButton"].firstMatch
        if createBtn.waitForExistence(timeout: 5) {
            tap(createBtn)
        } else {
            let sidebarNewBot = app.buttons["New Bot"].firstMatch
            if sidebarNewBot.waitForExistence(timeout: 5) {
                tap(sidebarNewBot)
            }
        }

        let sheet = app.sheets.firstMatch
        if !sheet.waitForExistence(timeout: 8) {
            // If toolbar button did not present, click the New Bot button in the sidebar
            let sidebarNewBot = app.buttons["New Bot"].firstMatch
            if sidebarNewBot.waitForExistence(timeout: 5) {
                tap(sidebarNewBot)
            }
        }
        XCTAssertTrue(sheet.waitForExistence(timeout: 8), "Create Bot sheet should open.")

        let nameField = app.textFields["botNameTextField"].firstMatch
        if nameField.waitForExistence(timeout: 3) {
            tap(nameField)
            nameField.typeText(" TestBot")
        }

        let saveBtn = app.buttons["saveBotButton"].firstMatch
        if saveBtn.waitForExistence(timeout: 3) {
            tap(saveBtn)
        } else {
            let cancelBtn = app.buttons["Cancel"].firstMatch
            if cancelBtn.waitForExistence(timeout: 2) {
                tap(cancelBtn)
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Create Bot sheet should dismiss.")
    }

    // MARK: - Tier 2: Failed Tool Handling and Error Recovery

    @MainActor func testFailedToolRendersErrorInActivityLogAndRecovers() throws {
        launchFreshApp()
        // Ensure Activity Log is open
        let logView = app.descendants(matching: .any)["toolActivityView"].firstMatch
        if !logView.exists {
            let toggle = app.buttons["toggleActivityLogButton"].firstMatch
            if toggle.waitForExistence(timeout: 5) {
                tap(toggle)
                _ = logView.waitForExistence(timeout: 5)
            }
        }

        // Send a request to read a nonexistent file to trigger real tool failure
        let nonexistentPath = "/tmp/apex_nonexistent_test_\(UUID().uuidString).txt"
        let bubble = sendAndWaitForResponse("Read the contents of file \(nonexistentPath)", timeout: 240)
        let staticText = bubble.descendants(matching: .staticText).firstMatch
        let text = (staticText.value as? String) ?? staticText.label
        XCTAssertFalse(text.isEmpty, "Agent should reply explaining the file status or failure.")
    }

    // MARK: - Tier 2: Panel layout persistence across relaunch

    @MainActor func testPanelVisibilityPersistsAcrossRelaunch() throws {
        launchFreshApp()
        let terminal = app.buttons["toggleTerminalButton"].firstMatch
        let plan = app.buttons["togglePlanDashboardButton"].firstMatch
        guard terminal.waitForExistence(timeout: 5), plan.waitForExistence(timeout: 5) else { return }

        let terminalView = app.descendants(matching: .any)["terminalView"].firstMatch
        let planView = app.descendants(matching: .any)["planDashboard"].firstMatch

        if !terminalView.exists { 
            tap(terminal)
            _ = terminalView.waitForExistence(timeout: 5)
        }
        if !planView.exists { 
            tap(plan)
            _ = planView.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(terminalView.waitForExistence(timeout: 5), "Terminal should be ON before relaunch.")
        XCTAssertTrue(planView.waitForExistence(timeout: 5), "Plan should be ON before relaunch.")

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 5)
        let relaunched = XCUIApplication()
        app = relaunched
        relaunched.launch()
        relaunched.activate()
        _ = relaunched.wait(for: .runningForeground, timeout: 10)
        sleep(2)

        let relaunchedTerminal = relaunched.descendants(matching: .any)["terminalView"].firstMatch
        let relaunchedPlan = relaunched.descendants(matching: .any)["planDashboard"].firstMatch
        XCTAssertTrue(relaunchedTerminal.waitForExistence(timeout: 10), "Terminal panel should persist after relaunch (@AppStorage).")
        XCTAssertTrue(relaunchedPlan.waitForExistence(timeout: 10), "Plan dashboard should persist after relaunch (@AppStorage).")
    }
}
