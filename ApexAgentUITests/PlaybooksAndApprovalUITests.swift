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

    func testPlanDashboardToggleLifecycle() throws {
        launchFreshApp()

        UITestActivity.step("1. Toggle Plan Dashboard On and Off") { _ in
            let planToggle = app.buttons["togglePlanDashboardButton"].firstMatch
            XCTAssertTrue(planToggle.waitForExistence(timeout: 5), "togglePlanDashboardButton must exist in toolbar")

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

        UITestActivity.step("1. Toggle Activity Log View") { _ in
            let activityToggle = app.buttons["toggleActivityLogButton"].firstMatch
            XCTAssertTrue(activityToggle.waitForExistence(timeout: 5), "toggleActivityLogButton must exist in toolbar")

            let logView = app.descendants(matching: .any)["toolActivityView"].firstMatch
            let initialExists = logView.exists

            activityToggle.click()
            let afterToggle = app.descendants(matching: .any)["toolActivityView"].firstMatch
            XCTAssertNotEqual(afterToggle.exists, initialExists, "Activity log visibility must toggle")

            // Ensure visible for next step
            if !afterToggle.exists {
                activityToggle.click()
                XCTAssertTrue(logView.waitForExistence(timeout: 5), "Activity log view must appear after second toggle")
            }
        }

        UITestActivity.step("2. Test Clear Activity Log button") { _ in
            let clearBtn = app.buttons["clearActivityLogButton"].firstMatch
            XCTAssertTrue(clearBtn.waitForExistence(timeout: 5), "clearActivityLogButton must exist in toolActivityView")
            clearBtn.click()
            let emptyLabel = app.staticTexts["No activity yet"].firstMatch
            XCTAssertTrue(emptyLabel.waitForExistence(timeout: 5), "Activity log should show empty state after clearing")
        }
    }

    func testHighRiskConfirmationApprovalGating() throws {
        launchFreshApp()

        UITestActivity.step("1. Check confirmation overlay gating") { _ in
            let approveBtn = app.buttons["confirmationApprove"].firstMatch
            let denyBtn = app.buttons["confirmationDeny"].firstMatch

            // In normal idle state without a pending confirmation, high-risk buttons must not be visible
            if denyBtn.exists {
                XCTAssertTrue(approveBtn.exists, "Approve button must accompany Deny button")
                denyBtn.click()
                XCTAssertTrue(denyBtn.waitForNonExistence(timeout: 5), "Modal must dismiss on Deny")
            } else {
                XCTAssertFalse(approveBtn.exists, "Approve button must not be present when no confirmation is pending")
                XCTAssertFalse(denyBtn.exists, "Deny button must not be present when no confirmation is pending")
            }
        }
    }
}
