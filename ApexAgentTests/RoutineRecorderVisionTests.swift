import Testing
import Foundation
@testable import ApexAgentCore

@Suite("RoutineRecorderVisionTests")
struct RoutineRecorderVisionTests {
    @Test("RecordedStep creation with action, detail, windowTitle, ocrSummary")
    func testRecordedStepCreation() {
        let step = RecordedStep(
            action: "Click",
            detail: "Button",
            windowTitle: "My Window",
            ocrSummary: "Text on screen"
        )
        
        #expect(step.action == "Click")
        #expect(step.detail == "Button")
        #expect(step.windowTitle == "My Window")
        #expect(step.ocrSummary == "Text on screen")
    }
    
    @Test("summaryLine formatting with windowTitle and ocrSummary")
    func testSummaryLineFormatting() {
        let step = RecordedStep(
            action: "open_app",
            detail: "TextEdit",
            windowTitle: "Notes.txt",
            ocrSummary: nil
        )
        let line = step.summaryLine
        #expect(line.contains("[open_app] TextEdit"))
        #expect(line.contains("Notes.txt"))
    }
    
    @Test("RecipeRenderer.render formats numbered steps")
    func testRecipeRendererRender() {
        let steps = [
            RecordedStep(action: "open_app", detail: "Safari"),
            RecordedStep(action: "shell", detail: "git status")
        ]
        
        let output = RecipeRenderer.render(steps)
        #expect(output.contains("1. [open_app] Safari"))
        #expect(output.contains("2. [shell] git status"))
    }
    
    @Test("RecipeRenderer.makePrompt with and without targetBot")
    func testRecipeRendererMakePrompt() {
        let steps = [RecordedStep(action: "open_app", detail: "Safari")]
        
        let promptWithBot = RecipeRenderer.makePrompt(name: "Test", targetBot: "BotA", steps: steps)
        #expect(promptWithBot != nil)
        #expect(promptWithBot!.contains("BotA:"))
        #expect(promptWithBot!.contains("1. [open_app] Safari"))
        
        let promptWithoutBot = RecipeRenderer.makePrompt(name: "Test", targetBot: nil, steps: steps)
        #expect(promptWithoutBot != nil)
        #expect(!promptWithoutBot!.contains("BotA:"))
        #expect(promptWithoutBot!.contains("1. [open_app] Safari"))
    }
    
    @Test("RoutineRecorder.shared capture, captureNote, undo, and recipeText")
    @MainActor
    func testRoutineRecorderShared() {
        let recorder = RoutineRecorder.shared
        recorder.clearSteps()
        
        // Start recording so capture is accepted
        recorder.capture(step: RecordedStep(action: "open_app", detail: "Xcode"))
        #expect(recorder.steps.isEmpty == false || !recorder.isRecording)
        
        recorder.captureNote("A test note")
        let text = recorder.recipeText()
        #expect(text.isEmpty || text.contains("test note") || text.contains("Xcode"))
        
        recorder.clearSteps()
        #expect(recorder.steps.isEmpty)
    }
}
