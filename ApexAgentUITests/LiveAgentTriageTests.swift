import XCTest

// MARK: - Live Triage Tests (Deterministic pass/fail style + optional live endpoint assertion)

@MainActor
final class LiveAgentTriageTests: XCTestCase {

    private var app: XCUIApplication!

    private func launchFreshApp() {
        continueAfterFailure = false
        if let app { app.terminate() }
        let fresh = XCUIApplication()
        fresh.launchEnvironment["APEX_TEST_MODE"] = "1"
        app = fresh
        fresh.launch()
        fresh.activate()
        sleep(1)
    }

    override func tearDown() async throws {
        if let app {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 5)
        }
    }

    /// Triage an agent response: test chat input, verify send button gating,
    /// send prompt, and verify response generation or user message bubble rendering.
    func testLiveAgentResponseTriage() throws {
        launchFreshApp()
        let chatInput = app.textViews["chatInputField"].firstMatch
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10),
                      "Chat input field is missing — app failed to render.")

        let sendButton = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button must exist")
        XCTAssertFalse(sendButton.isEnabled, "Send button must be disabled when input is empty")

        chatInput.click()
        let livePrompt = "Live Integration Test Check. Reply with the exact phrase: System OK"
        chatInput.typeText(livePrompt)

        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: sendButton, handler: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Send button must become enabled after typing prompt")

        sendButton.click()

        if ProcessInfo.processInfo.environment["APEX_LIVE_E2E"] == "1" {
            let agentResponseBubble = app.descendants(matching: .any)["AgentResponse"].firstMatch
            let responsePredicate = NSPredicate(format: "exists == true")
            let responseExpectation = expectation(for: responsePredicate, evaluatedWith: agentResponseBubble, handler: nil)
            let result = XCTWaiter().wait(for: [responseExpectation], timeout: 45.0)

            if result != .completed {
                let screenshot = app.windows.firstMatch.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = "Live_Timeout_State"
                attachment.lifetime = .keepAlways
                XCTFail("TRIAGE FAILURE: The live agent did not respond within 45s.")
            } else {
                let actualText = agentResponseBubble.label
                print("TRIAGE SUCCESS: Received live response text -> [\(actualText)]")
            }
        } else {
            let userBubble = app.scrollViews["conversationScrollView"]
                .descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
            XCTAssertTrue(userBubble.waitForExistence(timeout: 10), "User message bubble should render after send")
        }
    }

    /// Full lifecycle triage: verify input, send, and verify response.
    func testLiveAgentFullResponseTriage() throws {
        launchFreshApp()

        let chatInput = app.textViews["chatInputField"].firstMatch
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10), "Chat input field must exist")
        let sendButton = app.buttons["sendButton"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5), "Send button must exist")
        XCTAssertFalse(sendButton.isEnabled, "Send button must be disabled when input is empty")

        chatInput.click()
        chatInput.typeText("Reply with the exact phrase: System OK")

        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: sendButton, handler: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "Send button must become enabled")
        sendButton.click()

        if ProcessInfo.processInfo.environment["APEX_LIVE_E2E"] == "1" {
            let agentResponseBubble = app.descendants(matching: .any)["AgentResponse"].firstMatch
            XCTAssertTrue(agentResponseBubble.waitForExistence(timeout: 15))

            let contentPredicate = NSPredicate(format: "value != '' AND value != nil")
            let gotContent = XCTWaiter.wait(
                for: [expectation(for: contentPredicate, evaluatedWith: agentResponseBubble)],
                timeout: 45
            ) == .completed
            XCTAssertTrue(gotContent, "Live endpoint returned no streamed content within 45s.")
            print("LIVE FULL RESPONSE: [\(agentResponseBubble.label)]")
        } else {
            let userBubble = app.scrollViews["conversationScrollView"]
                .descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "UserMessage_")).firstMatch
            XCTAssertTrue(userBubble.waitForExistence(timeout: 10), "User message bubble should render after send")
        }
    }
}
