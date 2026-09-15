import XCTest

@MainActor
final class PlaybooksAndApprovalUITests: XCTestCase {

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

    func testPlanDashboardToggleLifecycle() throws {
        launchFreshApp()

        try UITestActivity.step("1. Toggle Plan Dashboard On and Off") { _ in
            let planToggle = app.buttons["togglePlanDashboardButton"].firstMatch
            guard planToggle.waitForExistence(timeout: 5) else { return }

            let planView = app.descendants(matching: .any)["planDashboard"].firstMatch
            let initialExists = planView.exists

            planToggle.click()
            let afterFirstToggle = app.descendants(matching: .any)["planDashboard"].firstMatch
            XCTAssertNotEqual(afterFirstToggle.exists, initialExists, "Plan dashboard visibility must toggle")

            planToggle.click()
            let afterSecondToggle = app.descendants(matching: .any)["planDashboard"].firstMatch
            XCTAssertEqual(afterSecondToggle.exists, initialExists, "Plan dashboard should revert to initial state")
        }
    }

    func testToolActivityViewToggleAndClear() throws {
        launchFreshApp()

        try UITestActivity.step("1. Toggle Activity Log View") { _ in
            let activityToggle = app.buttons["toggleActivityLogButton"].firstMatch
            XCTAssertTrue(activityToggle.waitForExistence(timeout: 5))

            let logView = app.descendants(matching: .any)["toolActivityView"].firstMatch
            let initialExists = logView.exists

            activityToggle.click()
            let afterToggle = app.descendants(matching: .any)["toolActivityView"].firstMatch
            XCTAssertNotEqual(afterToggle.exists, initialExists)

            // Ensure visible for next step
            if !afterToggle.exists {
                activityToggle.click()
                _ = logView.waitForExistence(timeout: 5)
            }
        }

        try UITestActivity.step("2. Test Clear Activity Log button") { _ in
            let clearBtn = app.buttons["clearActivityLogButton"].firstMatch
            if clearBtn.waitForExistence(timeout: 2) {
                clearBtn.click()
                let emptyLabel = app.staticTexts["No activity yet"].firstMatch
                XCTAssertTrue(emptyLabel.waitForExistence(timeout: 3), "Activity log should show empty state after clearing")
            }
        }
    }

    func testHighRiskConfirmationApprovalGating() throws {
        launchFreshApp()

        try UITestActivity.step("1. Check presence and dismissal of confirmation buttons") { _ in
            let approveBtn = app.buttons["confirmationApprove"].firstMatch
            let denyBtn = app.buttons["confirmationDeny"].firstMatch

            if denyBtn.waitForExistence(timeout: 2) {
                XCTAssertTrue(approveBtn.exists)
                denyBtn.click()
                XCTAssertTrue(denyBtn.waitForNonExistence(timeout: 5), "Modal must dismiss on Deny")
            }
        }
    }
}
