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

    func testDiagnosticsSheetSelfCheckLifecycle() throws {
        launchFreshApp()

        try UITestActivity.step("1. Open Diagnostics Sheet") { _ in
            let diagBtn = app.buttons["diagnosticsButton"].firstMatch
            XCTAssertTrue(diagBtn.waitForExistence(timeout: 5), "Diagnostics button should exist in toolbar")
            diagBtn.click()

            let diagSheet = app.sheets.firstMatch
            XCTAssertTrue(diagSheet.waitForExistence(timeout: 8), "Diagnostics sheet should open")
        }

        try UITestActivity.step("2. Dismiss Diagnostics Sheet") { _ in
            let doneBtn = app.buttons["diagnosticsDoneButton"].firstMatch
            if doneBtn.waitForExistence(timeout: 5) {
                doneBtn.click()
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
            let diagSheet = app.sheets.firstMatch
            XCTAssertTrue(diagSheet.waitForNonExistence(timeout: 5), "Diagnostics sheet should dismiss")
        }
    }

    func testToolCallingModePicker() throws {
        launchFreshApp()

        try UITestActivity.step("1. Inspect Tool Calling Mode Picker") { _ in
            let picker = app.popUpButtons["toolCallingModePicker"].firstMatch
            if picker.waitForExistence(timeout: 5) {
                picker.click()
                let autoItem = app.menuItems["Auto"].firstMatch
                if autoItem.waitForExistence(timeout: 2) {
                    autoItem.click()
                } else {
                    app.typeKey(.escape, modifierFlags: [])
                }
            } else {
                let altPicker = app.descendants(matching: .any)["toolCallingModePicker"].firstMatch
                XCTAssertTrue(altPicker.waitForExistence(timeout: 5), "Tool calling mode picker must exist")
            }
        }
    }
}
