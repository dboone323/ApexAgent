import XCTest

@MainActor
final class SettingsAndMCPDashboardUITests: XCTestCase {

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

    func testDiagnosticsSheetSelfCheckLifecycle() throws {
        launchFreshApp()

        UITestActivity.step("1. Open Diagnostics Sheet") { _ in
            let diagBtn = app.buttons["diagnosticsButton"].firstMatch
            XCTAssertTrue(diagBtn.waitForExistence(timeout: 5), "Diagnostics button should exist in toolbar")
            diagBtn.click()

            let diagSheet = app.sheets.firstMatch
            XCTAssertTrue(diagSheet.waitForExistence(timeout: 8), "Diagnostics sheet should open")
        }

        UITestActivity.step("2. Dismiss Diagnostics Sheet") { _ in
            let doneBtn = app.buttons["diagnosticsDoneButton"].firstMatch
            XCTAssertTrue(doneBtn.waitForExistence(timeout: 5), "diagnosticsDoneButton must exist on Diagnostics sheet")
            doneBtn.click()
            let diagSheet = app.sheets.firstMatch
            XCTAssertTrue(diagSheet.waitForNonExistence(timeout: 5), "Diagnostics sheet should dismiss")
        }
    }

    func testToolCallingModePickerTraversal() throws {
        launchFreshApp()

        UITestActivity.step("1. Inspect and cycle Tool Calling Mode Picker options") { _ in
            let picker = app.descendants(matching: .any)["toolCallingModePicker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "Tool calling mode picker must exist in toolbar")

            // Switch to Chat Only
            picker.click()
            let chatOnlyItem = app.menuItems["Chat Only"].firstMatch
            XCTAssertTrue(chatOnlyItem.waitForExistence(timeout: 3), "Chat Only menu item must exist")
            chatOnlyItem.click()

            // Switch back to Auto
            picker.click()
            let autoItem = app.menuItems["Auto"].firstMatch
            XCTAssertTrue(autoItem.waitForExistence(timeout: 3), "Auto menu item must exist")
            autoItem.click()
        }
    }

    func testSidebarToggleToolbarButton() throws {
        launchFreshApp()

        UITestActivity.step("1. Toggle sidebar visibility via toolbar button") { _ in
            let sidebarBtn = app.buttons["toggleSidebarButton"].firstMatch
            XCTAssertTrue(sidebarBtn.waitForExistence(timeout: 5), "toggleSidebarButton must exist in toolbar")
            sidebarBtn.click()

            // Toggle back
            sidebarBtn.click()
            let apexBot = app.buttons["botSidebarItem_Apex"].firstMatch
            XCTAssertTrue(apexBot.waitForExistence(timeout: 5), "Apex bot item must be visible in sidebar")
        }
    }
}
