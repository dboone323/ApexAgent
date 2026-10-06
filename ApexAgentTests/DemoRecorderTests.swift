import Testing
import Foundation
@testable import ApexAgentCore

@Suite("DemoRecorderTests")
struct DemoRecorderTests {
    @Test @MainActor func testDemoActionKind() {
        let click = DemoRecorder.ActionKind.mouseClick(button: "left", x: 10, y: 20, appName: "Safari", elementRole: nil, elementTitle: nil)
        #expect(click.badge.contains("Click"))
        #expect(click.appName == "Safari")
        let keys = DemoRecorder.ActionKind.keyStroke(characters: "hi", modifiers: "cmd", appName: "Xcode")
        #expect(keys.appName == "Xcode")
        let custom = DemoRecorder.ActionKind.customStep(description: "do thing")
        #expect(custom.appName.isEmpty)
    }

    @Test @MainActor func testRecordedAction() {
        let a = DemoRecorder.RecordedAction(kind: .customStep(description: "x"), description: " did stuff ")
        #expect(a.isWellFormed)
        #expect(a.formatAsMarkdown().contains("Custom Step"))
        let bad = DemoRecorder.RecordedAction(kind: .customStep(description: "x"), description: "   ")
        #expect(!bad.isWellFormed)
    }
}
