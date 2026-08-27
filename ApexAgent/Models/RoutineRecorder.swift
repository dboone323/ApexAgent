import Foundation
import AppKit
import Observation
import Vision

// MARK: - RecordedStep: one discrete action captured during a demo

/// A single step a user performed while "showing a Bot how it's done" (the
/// Grok Bot teach-a-task flow). Discrete and replayable: `action` is the kind
/// of step (`open_app`, `shell`, `applescript`, `note`), `detail` is the payload
/// (app name, command, script text, or a free-form note), and `occurredAt`
/// lets the recorder preserve ordering even across rapid captures.
struct RecordedStep: Identifiable, Equatable, Sendable {
    let id: UUID = UUID()
    let action: String
    let detail: String
    let occurredAt: Date

    var windowTitle: String? = nil
    var ocrSummary: String? = nil
    var screenshotImage: NSImage? = nil

    init(action: String, detail: String, occurredAt: Date = Date(), windowTitle: String? = nil, ocrSummary: String? = nil, screenshotImage: NSImage? = nil) {
        self.action = action
        self.detail = detail
        self.occurredAt = occurredAt
        self.windowTitle = windowTitle
        self.ocrSummary = ocrSummary
        self.screenshotImage = screenshotImage
    }

    /// A short human-readable line for the recipe/prompt.
    var summaryLine: String {
        var base = "[\(action)] \(detail)"
        if let windowTitle = windowTitle, !windowTitle.isEmpty {
            base += " (\"\(windowTitle)\")"
        } else if let ocrSummary = ocrSummary, !ocrSummary.isEmpty {
            base += " (\"\(ocrSummary)\")"
        }
        return base
    }
}

/// Renders recorded steps into a numbered, replayable recipe prompt.
/// Kept pure (no actor) so it is trivially unit-testable.
enum RecipeRenderer {
    /// Renders steps as a numbered recipe. Returns "" when there are no steps.
    static func render(_ steps: [RecordedStep]) -> String {
        guard !steps.isEmpty else { return "" }
        return steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.summaryLine)" }
            .joined(separator: "\n")
    }

    /// Builds the full routine prompt, optionally routing to a named Bot
    /// using the existing "<BotName>: <prompt>" convention that RoutineManager
    /// already parses.
    static func makePrompt(name _: String, targetBot: String?, steps: [RecordedStep]) -> String? {
        let body = RecipeRenderer.render(steps)
        guard !body.isEmpty else { return nil }
        let instruction = "Execute this recorded routine that I just showed you, step by step:\n\(body)"
        guard let targetBot, !targetBot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return instruction
        }
        return "\(targetBot): \(instruction)"
    }
}

// MARK: - RoutineRecorder: the teach-a-task / watch-and-learn service

/// The runtime object that watches the user do a job once and turns it into a
/// reusable `Routine` (Grok Bot's "Show a Bot how it's done"). It is a native
/// Swift observer: it subscribes to frontmost-app activation changes and also
/// accepts discrete `capture` hooks from the tool layer, so a demo can be
/// recorded either by watching the user or by the agent logging its own steps.
@Observable
@MainActor
final class RoutineRecorder {
    /// Shared recorder used by the UI/Settings affordances.
    static let shared = RoutineRecorder()

    private(set) var isRecording = false
    private(set) var steps: [RecordedStep] = []

    /// Hard cap so an unattended recorder can never accumulate unbounded steps.
    private let stepCap = 500
    private var activationObserver: NSObjectProtocol?

    // MARK: Record lifecycle

    /// Begins a recording session: clears prior steps and starts observing
    /// frontmost-app activation so "switched to tool X" is captured for free.
    func start() {
        guard !isRecording else { return }
        steps = []
        isRecording = true
        
        Task {
            await ScreenStreamer.shared.startCapture()
        }
        
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, self.isRecording else { return }
            guard let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication),
                  let name = app.localizedName,
                  !name.isEmpty else { return }
                  
            let image = ScreenStreamer.shared.getLatestFrame()
            self.capture(step: RecordedStep(action: "open_app", detail: name, screenshotImage: image))
        }
    }

    /// Stops recording and returns the captured steps.
    @discardableResult
    func stop() -> [RecordedStep] {
        isRecording = false
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        ScreenStreamer.shared.stopCapture()
        return steps
    }

    var hasSteps: Bool { !steps.isEmpty }

    // MARK: - Capturing steps

    /// Append a raw step; ignored when not recording or over the cap.
    func capture(step: RecordedStep) {
        guard isRecording, steps.count < stepCap else { return }
        steps.append(step)
    }

    func captureShell(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !trimmed.isEmpty else { return }
        capture(step: RecordedStep(action: "shell", detail: trimmed))
    }

    func captureAppleScript(_ script: String) {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !trimmed.isEmpty else { return }
        capture(step: RecordedStep(action: "applescript", detail: trimmed))
    }

    func captureNote(_ note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRecording, !trimmed.isEmpty else { return }
        capture(step: RecordedStep(action: "note", detail: trimmed))
    }

    func captureSnapshot(note: String? = nil) {
        let image = ScreenStreamer.shared.getLatestFrame()
        var ocrSummary: String? = nil
        
        if let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
            
            if let results = request.results {
                let texts = results.compactMap { $0.topCandidates(1).first?.string }
                if !texts.isEmpty {
                    ocrSummary = Array(texts.prefix(5)).joined(separator: ", ")
                }
            }
        }
        
        let detail = note ?? "Visual Snapshot"
        let step = RecordedStep(action: "snapshot", detail: detail, windowTitle: nil, ocrSummary: ocrSummary, screenshotImage: image)
        capture(step: step)
    }

    // MARK: - Corrections (user reviewing the demo)

    func undo() {
        _ = steps.popLast()
    }

    func clearSteps() {
        steps = []
    }

    // MARK: - Recipe / routine synthesis

    func recipeText() -> String {
        RecipeRenderer.render(steps)
    }

    /// Build a `Routine` whose prompt replays the recorded demo. Returns nil
    /// if there is nothing recorded. Persisting into SwiftData is left to the
    /// caller (RoutineManager.save).
    func makeRoutine(named name: String, targetBot: String? = nil) -> Routine? {
        guard let prompt = RecipeRenderer.makePrompt(name: name, targetBot: targetBot, steps: steps) else {
            return nil
        }
        return Routine(name: name, descriptionText: prompt, trigger: .manual, scheduledMinutes: 0, enabled: true)
    }
}
