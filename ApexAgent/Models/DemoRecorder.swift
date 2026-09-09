import Foundation
import AppKit
import ApplicationServices
import Observation

// MARK: - DemoRecorder: Teach-a-Task Demonstration Recording Engine (Grok Bot F2 / WS2)
//
// Allows users to demonstrate a workflow once (mouse clicks, keystrokes, application switches).
// DemoRecorder captures system interactions and synthesizes them into automated Routines
// (prompt instructions for Bots) or executable Skills (AppleScript / shell scripts in ~/.apex/skills).

@Observable
@MainActor
public final class DemoRecorder {
    public static let shared = DemoRecorder()

    public enum ActionKind: Sendable, Codable, Equatable {
        case mouseClick(button: String, x: Double, y: Double, appName: String, elementRole: String?, elementTitle: String?)
        case keyStroke(characters: String, modifiers: String, appName: String)
        case appSwitch(appName: String, bundleId: String)
        case customStep(description: String)
    }

    public struct RecordedAction: Identifiable, Sendable, Codable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let kind: ActionKind
        public let description: String

        public init(id: UUID = UUID(), timestamp: Date = Date(), kind: ActionKind, description: String) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.description = description
        }
    }

    public private(set) var isRecording: Bool = false
    public private(set) var recordedActions: [RecordedAction] = []
    public private(set) var recordingStartTime: Date?

    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var workspaceObserver: Any?

    public init() {}

    // MARK: - Lifecycle

    public func startRecording() {
        guard !isRecording else { return }
        clear()
        isRecording = true
        recordingStartTime = Date()

        // Capture currently active application
        if let frontApp = NSWorkspace.shared.frontmostApplication {
            recordAppSwitch(appName: frontApp.localizedName ?? "Unknown", bundleId: frontApp.bundleIdentifier ?? "")
        }

        // Listen for frontmost application changes
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let appName = app?.localizedName ?? "Unknown"
            let bundleId = app?.bundleIdentifier ?? ""
            Task { @MainActor [weak self] in
                guard let self = self, self.isRecording else { return }
                self.recordAppSwitch(appName: appName, bundleId: bundleId)
            }
        }

        // Global mouse/key event monitoring (requires Accessibility permissions)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .keyDown]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleObservedEvent(event)
            }
        }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleObservedEvent(event)
            }
            return event
        }
    }

    public func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let local = localEventMonitor {
            NSEvent.removeMonitor(local)
            localEventMonitor = nil
        }
        if let obs = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            workspaceObserver = nil
        }
    }

    public func clear() {
        recordedActions.removeAll()
        recordingStartTime = nil
    }

    // MARK: - Event Recording

    public func recordAction(kind: ActionKind, description: String) {
        let action = RecordedAction(kind: kind, description: description)
        recordedActions.append(action)
    }

    private func recordAppSwitch(appName: String, bundleId: String) {
        let desc = "Switched to application '\(appName)'"
        recordAction(kind: .appSwitch(appName: appName, bundleId: bundleId), description: desc)
    }

    private func handleObservedEvent(_ event: NSEvent) {
        guard isRecording else { return }
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "App"

        switch event.type {
        case .leftMouseDown, .rightMouseDown:
            let loc = event.locationInWindow
            let buttonName = event.type == .leftMouseDown ? "Left" : "Right"

            // Inspect accessibility attributes at click location if available
            var role: String? = nil
            var title: String? = nil
            let systemWide = AXUIElementCreateSystemWide()
            var elementRef: AXUIElement?
            if AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &elementRef) == .success,
               let elem = elementRef {
                var roleVal: AnyObject?
                if AXUIElementCopyAttributeValue(elem, kAXRoleAttribute as CFString, &roleVal) == .success {
                    role = roleVal as? String
                }
                var titleVal: AnyObject?
                if AXUIElementCopyAttributeValue(elem, kAXTitleAttribute as CFString, &titleVal) == .success {
                    title = titleVal as? String
                }
            }

            let elementDesc: String
            if let t = title, !t.isEmpty {
                elementDesc = " on '\(t)'"
            } else if let r = role, !r.isEmpty {
                elementDesc = " on \(r)"
            } else {
                elementDesc = ""
            }

            let desc = "\(buttonName) Click at (\(Int(loc.x)), \(Int(loc.y))) in \(appName)\(elementDesc)"
            recordAction(
                kind: .mouseClick(
                    button: buttonName,
                    x: Double(loc.x),
                    y: Double(loc.y),
                    appName: appName,
                    elementRole: role,
                    elementTitle: title
                ),
                description: desc
            )

        case .keyDown:
            let chars = event.charactersIgnoringModifiers ?? ""
            guard !chars.isEmpty else { return }
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("Cmd") }
            if event.modifierFlags.contains(.control) { mods.append("Ctrl") }
            if event.modifierFlags.contains(.option) { mods.append("Opt") }
            if event.modifierFlags.contains(.shift) { mods.append("Shift") }
            let modStr = mods.isEmpty ? "" : mods.joined(separator: "+") + "+"

            let displayChar: String
            if chars == "\r" { displayChar = "Return" }
            else if chars == "\t" { displayChar = "Tab" }
            else if chars == " " { displayChar = "Space" }
            else { displayChar = chars }

            let desc = "Key '\(modStr)\(displayChar)' in \(appName)"
            recordAction(
                kind: .keyStroke(characters: displayChar, modifiers: modStr, appName: appName),
                description: desc
            )

        default:
            break
        }
    }

    // MARK: - Synthesis

    /// Translates recorded steps into a natural-language step-by-step instruction prompt for Bots.
    public func synthesizeRoutinePrompt(routineName: String) -> String {
        guard !recordedActions.isEmpty else {
            return "Execute workflow '\(routineName)'."
        }

        var lines: [String] = [
            "Demonstrated workflow '\(routineName)':",
            "Follow these recorded steps in sequence to reproduce the user's task:"
        ]

        for (index, action) in recordedActions.enumerated() {
            lines.append("\(index + 1). \(action.description)")
        }

        lines.append("Verify completion and report final status.")
        return lines.joined(separator: "\n")
    }

    /// Translates recorded steps into an automated AppleScript / bash automation script.
    public func synthesizeShellScript(skillName: String) -> String {
        var script = """
        #!/usr/bin/env bash
        # Generated by ApexAgent Teach-a-Task DemoRecorder
        # Skill: \(skillName)
        set -euo pipefail

        echo "Executing demonstrated task: \(skillName)..."

        """

        var appleScriptLines: [String] = []
        for action in recordedActions {
            switch action.kind {
            case .appSwitch(let appName, _):
                appleScriptLines.append("tell application \"\(appName)\" to activate")
                appleScriptLines.append("delay 0.5")
            case .mouseClick(_, let x, let y, _, _, _):
                // Using clisclick or system event coordinates
                appleScriptLines.append("# Click at (\(Int(x)), \(Int(y)))")
            case .keyStroke(let char, let mod, _):
                if mod.contains("Cmd") {
                    appleScriptLines.append("tell application \"System Events\" to keystroke \"\(char.lowercased())\" using command down")
                } else if char == "Return" {
                    appleScriptLines.append("tell application \"System Events\" to key code 36")
                } else if char == "Tab" {
                    appleScriptLines.append("tell application \"System Events\" to key code 48")
                } else if char == "Space" {
                    appleScriptLines.append("tell application \"System Events\" to keystroke \" \"")
                } else {
                    appleScriptLines.append("tell application \"System Events\" to keystroke \"\(char)\"")
                }
                appleScriptLines.append("delay 0.2")
            case .customStep(let desc):
                appleScriptLines.append("# \(desc)")
            }
        }

        if !appleScriptLines.isEmpty {
            let combined = appleScriptLines.joined(separator: "\n")
            script += """
            osascript << 'EOF'
            \(combined)
            EOF

            """
        }

        script += """
        echo "Workflow '\(skillName)' finished successfully."
        exit 0
        """
        return script
    }
}
