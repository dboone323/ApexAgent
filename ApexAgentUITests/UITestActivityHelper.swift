import XCTest

/// Structured test activity and diagnostic attachment helpers for rich XCUITest .xcresult reports.
@MainActor
public enum UITestActivity {
    
    /// Executes a synchronous block inside a named XCTContext activity step.
    public static func step(_ name: String, block: (XCTActivity) throws -> Void) rethrows {
        try XCTContext.runActivity(named: name) { activity in
            try block(activity)
        }
    }
    
    /// Captures a screenshot of an element (or window) and attaches it to the current activity or test case.
    public static func attachScreenshot(of element: XCUIElement, named name: String, to activity: XCTActivity? = nil) {
        let screenshot = element.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        activity?.add(attachment)
    }
    
    /// Captures the full UI accessibility hierarchy dump and attaches it as text.
    public static func attachHierarchy(of app: XCUIApplication, named name: String = "UI_Hierarchy", to activity: XCTActivity? = nil) {
        let dump = app.debugDescription
        let attachment = XCTAttachment(string: dump)
        attachment.name = name
        attachment.lifetime = .keepAlways
        activity?.add(attachment)
    }
}
