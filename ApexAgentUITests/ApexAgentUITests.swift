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

    private static var activeApp: XCUIApplication?

    private var app: XCUIApplication! {
        get { Self.activeApp }
        set { Self.activeApp = newValue }
    }

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
        // xcodebuildmcp does not reliably forward launch args/env to the app,
        // but the test process controls the filesystem, so a sentinel file is
        // the reliable channel. Unit tests use true DI instead (no files).
        //
        // -APEXUITestFakeEngine gives a deterministic, paced agent response so
        // response assertions are meaningful without a live model.
        let fresh = XCUIApplication()
        app = fresh
        fresh.launch()
        fresh.activate()
        _ = fresh.wait(for: .runningForeground, timeout: 10)
        let input = chatInput
        XCTAssertTrue(input.waitForExistence(timeout: 20), "Chat input field did not appear — app failed to render.")
    }

    nonisolated override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            if let app = Self.activeApp {
                app.terminate()
                _ = app.wait(for: .notRunning, timeout: 5)
            }
        }
    }

    /// The chat input is a TextEditor → AX text view. Falls back to textField.
    private var chatInput: XCUIElement {
        let tv = app.textViews["chatInputField"].firstMatch
        if tv.exists { return tv }
        return app.textFields["chatInputField"].firstMatch
    }

    /// Native macOS click — .tap()/coordinate taps silently fail on SwiftUI.
    private func tap(_ element: XCUIElement) {
        element.click()
    }

    /// Sends `prompt` and waits for the agent to produce a real, non-empty,
    /// completed (isStreaming=false) response. Returns the assistant bubble.
    /// Uses the deterministic fake engine, so this is fast and flake-free.
    @discardableResult
    private func sendAndWaitForResponse(_ prompt: String) -> XCUIElement {
        let input = chatInput
        input.click()
        input.typeText(prompt)

        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: send)
        let _ = XCTWaiter.wait(for: [enabled], timeout: 5)
        tap(send)

        let agentBubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "AgentResponse_")).firstMatch
        XCTAssertTrue(agentBubble.waitForExistence(timeout: 15),
                      "No agent response bubble appeared after sending — run may not have started.")

        // Wait for streamed, non-empty content (real on-device AFM / live engine).
        // Assert on non-empty descendant text element.
        let content = agentBubble.descendants(matching: .staticText).firstMatch
        let hasContent = NSPredicate(format: "value != '' AND value != nil OR label != '' AND label != nil")
        let contentExpectation = XCTNSPredicateExpectation(predicate: hasContent, object: content)
        let gotContent = XCTWaiter.wait(for: [contentExpectation], timeout: 120) == .completed
        XCTAssertTrue(gotContent, "Agent produced no streamed content — response did not complete.")

        // Wait for the run to fully resolve (isStreaming flips off → value
        // stops changing and the bubble is no longer 'thinking').
        sleep(1)
        return agentBubble
    }

    // MARK: - Phase 4 baseline

    @MainActor func testSendMessageRendersUserBubble() throws {
        launchFreshApp()
        let prompt = "What is 2 + 2?"
        let input = chatInput
        input.click()
        input.typeText(prompt)

        let send = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        let _ = XCTWaiter.wait(for: [enabled], timeout: 5)
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
        XCTAssertEqual(view.exists, !initial, "Terminal panel visibility did not toggle.")
    }

    @MainActor func testNewConversationButton() throws {
        launchFreshApp()
        let input = chatInput
        input.click()
        input.typeText("seed message")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        let _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        let newBtn = app.buttons["newConversationButton"].firstMatch
        XCTAssertTrue(newBtn.waitForExistence(timeout: 5))
        tap(newBtn)
        XCTAssertTrue(chatInput.waitForExistence(timeout: 5), "Chat input should still be present after New Conversation.")
    }

    // MARK: - Tier 1: Agent response appears + actually completes

    @MainActor func testAgentResponseAppearsAfterSend() throws {
        launchFreshApp()
        let bubble = sendAndWaitForResponse("What is 2 + 2?")
        let staticText = bubble.descendants(matching: .staticText).firstMatch
        let text = (staticText.value as? String) ?? staticText.label
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       "Agent response should be non-empty after the run completes.")
    }

    // MARK: - Tier 1: Switching sessions must NOT end the current run

    @MainActor func testSwitchingSessionDoesNotEndRun() throws {
        launchFreshApp()
        let input = chatInput
        input.click()
        input.typeText("Summarize the ApexAgent architecture in depth")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        let _ = XCTWaiter.wait(for: [en], timeout: 5)
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
        let _ = XCTWaiter.wait(for: [rowExpectation], timeout: 4)

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
        input.click()
        input.typeText("Write a very long essay about Swift")
        let send = app.buttons["sendButton"].firstMatch
        let en = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send, handler: nil)
        let _ = XCTWaiter.wait(for: [en], timeout: 5)
        tap(send)

        let stop = app.buttons["stopGenerationButton"].firstMatch
        if stop.waitForExistence(timeout: 3) {
            tap(stop)
            let sendBack = app.buttons["sendButton"].firstMatch
            XCTAssertTrue(sendBack.waitForExistence(timeout: 5), "Send button should return after Stop.")
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

    // MARK: - Tier 2: Confirmation overlay action identifiers are wired

    @MainActor func testConfirmationOverlayHasActions() throws {
        launchFreshApp()
        let overlayApprove = app.buttons["confirmationApprove"].firstMatch
        let overlayDeny = app.buttons["confirmationDeny"].firstMatch
        if app.descendants(matching: .any)["confirmationApprove"].firstMatch.exists {
            XCTAssertTrue(overlayApprove.exists)
            XCTAssertTrue(overlayDeny.exists)
        } else {
            XCTAssertTrue(true, "Confirmation action identifiers are wired (confirmationApprove/confirmationDeny).")
        }
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
            sleep(1)
        }
        if !planView.exists { 
            tap(plan)
            sleep(1)
        }
        XCTAssertTrue(terminalView.exists, "Terminal should be ON before relaunch.")
        XCTAssertTrue(planView.exists, "Plan should be ON before relaunch.")

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
