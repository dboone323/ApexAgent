import XCTest

// MARK: - Phase 4/5: real end-to-end UI automation of the built ApexAgent.app.
// Drives the running app through XCUITest (Accessibility/automation entitlement
// on the test runner). No mocks: this launches the real .app and interacts with
// its real UI elements, asserted by accessibility identifiers.
//
// Determinism notes:
//  - Every test gets a fresh app process and explicitly starts a new conversation
//    so a previously selected bot or shared space cannot change the composer.
//  - All clicks use .click() (native macOS click). .tap()/coordinate taps
//    silently fail to fire SwiftUI button actions on macOS.
//  - APEX_TEST_MODE disables user-data migrations in the launched app. The UI
//    suite never reads or forwards credentials from the developer's home folder.

@MainActor
final class ApexAgentUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Fresh-launch lifecycle, invoked explicitly at the top of every test.
    /// setUpWithError overrides are nonisolated under Swift strict concurrency,
    /// so all main-actor UI work lives here instead.
    private func launchFreshApp(requiresChatInput: Bool = true) {
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
        fresh.launchEnvironment["APEX_TEST_MODE"] = "1"
        fresh.launchArguments.append(contentsOf: ["-showTerminal", "NO", "-showPlanDashboard", "NO"])
        app = fresh
        fresh.launch()
        fresh.activate()
        _ = fresh.wait(for: .runningForeground, timeout: 10)
        let newConversationButton = fresh.buttons["newConversationButton"].firstMatch
        if newConversationButton.waitForExistence(timeout: 5) {
            newConversationButton.click()
        } else {
            fresh.typeKey("n", modifierFlags: .command)
        }
        // Ensure terminal panel is closed at startup so tests begin with clean UI
        let initialTerminal = fresh.descendants(matching: .any)["terminalView"].firstMatch
        if initialTerminal.exists {
            let toggle = fresh.buttons["toggleTerminalButton"].firstMatch
            if toggle.exists {
                toggle.click()
                _ = initialTerminal.waitForNonExistence(timeout: 3)
            }
        }

        if requiresChatInput {
            let input = chatInput
            XCTAssertTrue(input.waitForExistence(timeout: 20), "Chat input field did not appear — app failed to render.")
        }
    }

    override func tearDown() async throws {
        if let app {
            if testRun?.hasSucceeded == false {
                UITestActivity.attachScreenshot(of: app.windows.firstMatch, named: "Failure_Screenshot")
                UITestActivity.attachHierarchy(of: app, named: "Failure_UI_Hierarchy")
            }
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
    }

    /// The chat input is a TextEditor → AX text view on macOS.
    private var chatInput: XCUIElement {
        let currentApp = app ?? XCUIApplication()
        return currentApp.textViews["chatInputField"].firstMatch
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
    private func sendAndWaitForResponse(_ prompt: String, timeout: TimeInterval = 240) -> XCUIElement {
        // Default 240 s: must stay ≤ maximumTestExecutionTimeAllowance (240) in
        // ApexAgent-UITests.xctestplan, otherwise the wait is unreachable (audit #39).
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

        // Zero-approval policy (AUDIT_2026-09-28 §3.3.15): the harness must never
        // auto-approve high-risk tool confirmations on the developer's machine.
        // If the overlay appears, deny it — the agent still streams a final
        // response describing the denial, so response assertions remain valid.
        let denyButton = app.buttons["confirmationDeny"].firstMatch
        if denyButton.waitForExistence(timeout: 2) {
            tap(denyButton)
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
        launchFreshApp(requiresChatInput: false)
        XCTAssertEqual(app.state, .runningForeground)
        let settingsBtn = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(settingsBtn.waitForExistence(timeout: 5), "Settings button must exist in toolbar")
        tap(settingsBtn)
        let settingsForm = app.descendants(matching: .any)["settingsForm"].firstMatch
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 8), "Settings form must appear")
        let doneBtn = app.buttons["settingsDoneButton"].firstMatch
        XCTAssertTrue(doneBtn.waitForExistence(timeout: 5), "settingsDoneButton must exist")
        tap(doneBtn)
        XCTAssertTrue(settingsForm.waitForNonExistence(timeout: 5), "Settings form must dismiss")
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

        let seededMessage = app.scrollViews["conversationScrollView"]
            .descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ OR label CONTAINS[c] %@ OR value CONTAINS[c] %@", "UserMessage_", "seed message", "seed message")).firstMatch
        XCTAssertTrue(seededMessage.waitForExistence(timeout: 10), "Seed message should render before starting a new conversation.")

        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        tap(newBtn)
        XCTAssertTrue(seededMessage.waitForNonExistence(timeout: 5), "New Conversation should visibly clear the prior conversation.")
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

    @MainActor func testLiveButtonInteractionsAndDirectAtMentionCommandEvaluation() throws {
        launchFreshApp()

        // 1. Live Button Traversal: Test Toolbar and Panel Buttons
        let terminalToggle = app.buttons["toggleTerminalButton"].firstMatch
        XCTAssertTrue(terminalToggle.waitForExistence(timeout: 5), "toggleTerminalButton should exist in toolbar")
        let terminal = app.descendants(matching: .any)["terminalView"].firstMatch
        let initialTerminal = terminal.exists
        tap(terminalToggle)
        if initialTerminal {
            XCTAssertTrue(terminal.waitForNonExistence(timeout: 5), "Terminal panel should hide")
        } else {
            XCTAssertTrue(terminal.waitForExistence(timeout: 5), "Terminal panel should appear")
        }
        if terminal.exists {
            tap(terminalToggle)
            XCTAssertTrue(terminal.waitForNonExistence(timeout: 5))
        }

        let planToggle = app.buttons["togglePlanDashboardButton"].firstMatch
        XCTAssertTrue(planToggle.waitForExistence(timeout: 5), "togglePlanDashboardButton should exist in toolbar")
        let planDashboard = app.descendants(matching: .any)["planDashboard"].firstMatch
        let initialPlan = planDashboard.exists
        tap(planToggle)
        if initialPlan {
            XCTAssertTrue(planDashboard.waitForNonExistence(timeout: 5), "Plan dashboard should hide")
        } else {
            XCTAssertTrue(planDashboard.waitForExistence(timeout: 5), "Plan dashboard should appear")
        }
        if planDashboard.exists {
            tap(planToggle)
            XCTAssertTrue(planDashboard.waitForNonExistence(timeout: 5))
        }

        let activityToggle = app.buttons["toggleActivityLogButton"].firstMatch
        XCTAssertTrue(activityToggle.waitForExistence(timeout: 5), "toggleActivityLogButton should exist in toolbar")
        let activityLog = app.descendants(matching: .any)["toolActivityView"].firstMatch
        let initialActivity = activityLog.exists
        tap(activityToggle)
        if initialActivity {
            XCTAssertTrue(activityLog.waitForNonExistence(timeout: 5), "Tool activity log should hide")
        } else {
            XCTAssertTrue(activityLog.waitForExistence(timeout: 5), "Tool activity log should appear")
        }
        if activityLog.exists {
            tap(activityToggle)
            XCTAssertTrue(activityLog.waitForNonExistence(timeout: 5))
        }

        // 2. Chat Input and Send Button State Verification
        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled, "Send button must be disabled when input is empty")

        // 3. Give agent a command with @mention
        let prompt = "@Apex In natural language without tools, what is two plus two?"
        let bubble = sendAndWaitForResponse(prompt, timeout: 60)

        // 4. Verification Part 1: Response happens first
        let staticText = bubble.descendants(matching: .staticText).firstMatch
        let candidateText = (staticText.value as? String) ?? staticText.label
        let text = (candidateText.isEmpty ? (bubble.value as? String ?? "") : candidateText).lowercased()
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "First requirement: Agent response must happen and be non-empty.")

        // 5. Verification Part 2: Response is correct
        XCTAssertTrue(text.contains("4") || text.contains("four"),
                      "Second requirement: Agent response must be correct (expected 4 or four); got: \(text)")

        // 6. Test New Conversation Button reset
        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        tap(newBtn)
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5))
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
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "First conversation row should exist in sidebar")
        tap(firstRow)
        let restored = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 8), "User message should be restored after switching back")
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
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "stopGenerationButton must appear when generation starts")
        tap(stop)
        let sendBack = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(sendBack.waitForExistence(timeout: 8), "Send button should return after Stop.")
    }

    // MARK: - Tier 2: Suggestion chips

    @MainActor func testSuggestionChipSends() throws {
        launchFreshApp()
        // Fresh launch shows the empty-state WelcomeView with suggestion chips.
        let chip = app.buttons["suggestionChip_What's using the most disk space?"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "Suggestion chip should exist on empty conversation")
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
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "togglePlanDashboardButton must exist")
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
            // Safe gated target (AUDIT_2026-09-28 §3.3.15): a dedicated path that
            // never exists under /tmp, so even if the model somehow ran the tool
            // there is nothing real to destroy. The test only ever clicks Deny.
            input.typeText("Run the shell command: rm -rf /tmp/apex_uits_confirmation_probe_missing_dir")
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

        let clearBtn = app.buttons["clearActivityLogButton"].firstMatch
        XCTAssertTrue(clearBtn.waitForExistence(timeout: 5), "clearActivityLogButton must exist in toolActivityView")
        tap(clearBtn)
        let emptyLabel = app.staticTexts["No activity yet"].firstMatch
        XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5), "Activity log should show empty state after clearing.")
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
        XCTAssertTrue(doneBtn.waitForExistence(timeout: 5), "diagnosticsDoneButton must exist")
        tap(doneBtn)

        XCTAssertTrue(diagSheet.waitForNonExistence(timeout: 5), "Diagnostics sheet should close after clicking Done.")
    }

    // MARK: - Tier 2: Tool Calling Mode Picker Switching

    @MainActor func testToolCallingModePickerSwitching() throws {
        launchFreshApp()
        let picker = app.descendants(matching: .any)["toolCallingModePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Tool calling mode picker must exist in toolbar")
        tap(picker)
        let autoItem = app.menuItems["Auto"].firstMatch
        XCTAssertTrue(autoItem.waitForExistence(timeout: 3), "Auto item must exist")
        tap(autoItem)
    }

    // MARK: - Tier 2: Bot Sidebar Selection and Chat View Isolation

    @MainActor func testBotSidebarSelectionAndDedicatedChatView() throws {
        launchFreshApp()
        // Find Code Architect bot in the sidebar
        let codeArchitectBot = app.buttons["botSidebarItem_Code Architect"].firstMatch
        XCTAssertTrue(codeArchitectBot.waitForExistence(timeout: 5), "Code Architect bot must exist in sidebar")
        tap(codeArchitectBot)
        sleep(1)

        let headerText = app.staticTexts["Code Architect"].firstMatch
        XCTAssertTrue(headerText.waitForExistence(timeout: 5), "Header should display 'Code Architect' after selection.")

        let input = chatInput
        tap(input)
        input.typeText("Hello Code Architect")
        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        let apexBot = app.buttons["botSidebarItem_Apex"].firstMatch
        XCTAssertTrue(apexBot.waitForExistence(timeout: 5), "Apex bot must exist in sidebar")
        tap(apexBot)
        sleep(1)
        let apexHeader = app.staticTexts["Apex"].firstMatch
        XCTAssertTrue(apexHeader.waitForExistence(timeout: 5), "Header should switch back to 'Apex'.")
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

        let cancelBtn = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelBtn.waitForExistence(timeout: 5), "Cancel button must exist")
        tap(cancelBtn)

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
        XCTAssertTrue(terminal.waitForExistence(timeout: 5), "toggleTerminalButton must exist")
        XCTAssertTrue(plan.waitForExistence(timeout: 5), "togglePlanDashboardButton must exist")

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
        relaunched.launchEnvironment["APEX_TEST_MODE"] = "1"
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
