import Testing
import Foundation
import FoundationModels
import AppKit
@testable import ApexAgentCore

@MainActor
@Suite("RoutineRecorderTests")
struct RoutineRecorderTests {

    @Test func recorderIgnoresCapturesWhenIdle() {
        let recorder = RoutineRecorder()
        recorder.captureShell("echo hi")
        #expect(recorder.steps.isEmpty)
        #expect(!recorder.hasSteps)
    }

    @Test func startStopCapturesTypedSteps() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("open ~/project")
        recorder.captureAppleScript("tell app \"Safari\" to activate")
        recorder.captureNote("then approve the build")
        let steps = recorder.stop()
        #expect(steps.count == 3)
        #expect(recorder.steps.map(\.action) == ["shell", "applescript", "note"])
        #expect(recorder.isRecording == false)
    }

    @Test func stopKeepsRecordingSessionForReview() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("ls")
        recorder.stop()
        #expect(recorder.hasSteps)
        #expect(recorder.recipeText().contains("1. [shell] ls"))
    }

    @Test func undoRemovesLastStep() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("one")
        recorder.captureShell("two")
        recorder.undo()
        #expect(recorder.steps.count == 1)
        #expect(recorder.steps.first?.detail == "one")
    }

    @Test func makeRoutineRendersNumberedRecipe() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("open ~/project")
        recorder.captureNote("wait for build")
        recorder.stop()
        let routine = recorder.makeRoutine(named: "weekly-report")
        #expect(routine != nil)
        #expect(routine?.descriptionText.contains("1. [shell] open ~/project") == true)
        #expect(routine?.descriptionText.contains("2. [note] wait for build") == true)
    }

    @Test func makeRoutineRoutesToTargetBot() {
        let recorder = RoutineRecorder()
        recorder.start()
        recorder.captureShell("ls")
        recorder.stop()
        let routine = recorder.makeRoutine(named: "r", targetBot: "Ops")
        #expect(routine?.descriptionText.hasPrefix("Ops: ") == true)
    }

    @Test func makeRoutineNilWhenNothingRecorded() {
        let recorder = RoutineRecorder()
        #expect(recorder.makeRoutine(named: "x") == nil)
    }
}
