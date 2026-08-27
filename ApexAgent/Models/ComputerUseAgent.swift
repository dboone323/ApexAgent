import Foundation
import AppKit
import CoreGraphics

public enum ComputerAction: Equatable, Sendable, Codable {
    case click(x: Int, y: Int)
    case doubleClick(x: Int, y: Int)
    case type(text: String)
    case keyCombo(keys: [String])
    case scroll(deltaX: Int, deltaY: Int)
    case openApp(name: String)
    case wait(seconds: Double)
    case finish(result: String)
    case fail(reason: String)

    public var humanReadableSummary: String {
        switch self {
        case .click(let x, let y): return "click at (\(x), \(y))"
        case .doubleClick(let x, let y): return "double-click at (\(x), \(y))"
        case .type(let text): return "type '\(text.prefix(40))'"
        case .keyCombo(let keys): return "key combo: \(keys.joined(separator: "+"))"
        case .scroll(let dx, let dy): return "scroll by (\(dx), \(dy))"
        case .openApp(let name): return "open app: \(name)"
        case .wait(let seconds): return "wait \(seconds)s"
        case .finish(let result): return "finish: \(result.prefix(40))"
        case .fail(let reason): return "fail: \(reason.prefix(40))"
        }
    }
}

public struct ComputerUseStep: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let turn: Int
    public let action: ComputerAction
    public let observation: String
    public let timestamp: Date

    public init(id: UUID = UUID(), turn: Int = 0, action: ComputerAction, observation: String = "", timestamp: Date = Date()) {
        self.id = id
        self.turn = turn
        self.action = action
        self.observation = observation
        self.timestamp = timestamp
    }
}

@MainActor @Observable public final class ComputerUseAgent {
    public static let shared = ComputerUseAgent()

    public private(set) var isRunning: Bool = false
    public private(set) var history: [ComputerUseStep] = []
    public var maxTurns: Int = 15

    /// True when this process holds the Accessibility trust required to post
    /// synthetic keyboard/mouse events (System Settings › Privacy & Security ›
    /// Accessibility). Input actions surface an actionable error when missing.
    public static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Shared HID-level event source. Using `.combinedSessionState` means our
    /// synthetic events participate coherently with the user's physical session.
    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    private init() {}

    public func executeAction(_ action: ComputerAction) async throws -> String {
        switch action {
        case .click(let x, let y):
            return try await click(x: x, y: y, double: false)
        case .doubleClick(let x, let y):
            return try await click(x: x, y: y, double: true)
        case .type(let text):
            return try await typeText(text)
        case .keyCombo(let keys):
            return try pressKeyCombo(keys)
        case .scroll(let deltaX, let deltaY):
            return try scrollWheel(dx: deltaX, dy: deltaY)
        case .openApp(let name):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                NSWorkspace.shared.open(url)
                return "Opened app: \(name)"
            }
            return "Failed to open app: \(name)"
        case .wait(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited for \(seconds) seconds"
        case .finish(let result):
            return "Finished with result: \(result)"
        case .fail(let reason):
            return "Failed: \(reason)"
        }
    }

    // MARK: - Input Synthesis (CGEvent)

    /// Throws an actionable error unless the process is trusted for Accessibility.
    private func ensureAccessibility() throws {
        guard Self.hasAccessibilityPermission else {
            throw NSError(
                domain: "ComputerUseAgent", code: -10,
                userInfo: [NSLocalizedDescriptionKey: "ACCESSIBILITY_PERMISSION_REQUIRED: Enable ApexAgent in System Settings > Privacy & Security > Accessibility to allow computer-use input. Observation-only actions still work."]
            )
        }
    }

    private func click(x: Int, y: Int, double: Bool) async throws -> String {
        try ensureAccessibility()
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))
        postMouse(.mouseMoved, at: point)

        if double {
            // Real double-clicks are a normal pair followed by a clickState-2 pair.
            postMouse(.leftMouseDown, at: point, clickState: 1)
            postMouse(.leftMouseUp, at: point, clickState: 1)
            try await Task.sleep(nanoseconds: 40_000_000)
            postMouse(.leftMouseDown, at: point, clickState: 2)
            postMouse(.leftMouseUp, at: point, clickState: 2)
            return "Double clicked at (\(x), \(y))"
        }

        postMouse(.leftMouseDown, at: point)
        try await Task.sleep(nanoseconds: 15_000_000)
        postMouse(.leftMouseUp, at: point)
        return "Clicked at (\(x), \(y))"
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, clickState: Int64 = 1) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String) async throws -> String {
        try ensureAccessibility()
        var typed = 0
        for char in text {
            let utf16Units = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) else { continue }
            utf16Units.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: utf16Units.count,
                                              unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            typed += 1
        }
        return "Typed \(typed) character(s): \"\(text.prefix(120))\""
    }

    private func pressKeyCombo(_ keys: [String]) throws -> String {
        try ensureAccessibility()
        // Resolve every token BEFORE posting anything so an invalid combo is inert.
        var modifiers: [(name: String, flag: CGEventFlags)] = []
        var regularKeys: [String] = []
        for rawToken in keys {
            let token = rawToken.lowercased().trimmingCharacters(in: .whitespaces)
            if let flag = Self.modifierFlags[token] {
                modifiers.append((token, flag))
            } else if Self.specialKeyCodes[token] != nil || token.count == 1 {
                regularKeys.append(token)
            } else {
                return "⚠️ Unknown key name '\(rawToken)'. Supported modifiers: command/cmd, shift, option/alt, control/ctrl; plus single characters and named keys (return, tab, space, delete, escape, arrows, f1–f12)."
            }
        }
        guard !regularKeys.isEmpty || !modifiers.isEmpty else {
            return "⚠️ Empty key combo."
        }

        let allFlags = modifiers.reduce(CGEventFlags()) { $0.union($1.flag) }
        // Hold modifiers down, tap regular keys while held, release in reverse.
        for mod in modifiers {
            postKey(virtualKey: Self.modifierKeyCodes[mod.name] ?? 0, keyDown: true, flags: allFlags)
        }
        for key in regularKeys {
            let keyCode = Self.specialKeyCodes[key] ?? 0
            postKey(virtualKey: keyCode, keyDown: true, flags: allFlags)
            postKey(virtualKey: keyCode, keyDown: false, flags: allFlags)
        }
        for mod in modifiers.reversed() {
            postKey(virtualKey: Self.modifierKeyCodes[mod.name] ?? 0, keyDown: false, flags: [])
        }
        return "Pressed keys: \(keys.joined(separator: " + "))"
    }

    private func postKey(virtualKey: CGKeyCode, keyDown: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: eventSource,
                                  virtualKey: virtualKey, keyDown: keyDown) else { return }
        if !flags.isEmpty { event.flags = flags }
        event.post(tap: .cghidEventTap)
    }

    private func scrollWheel(dx: Int, dy: Int) throws -> String {
        try ensureAccessibility()
        guard dx != 0 || dy != 0 else { return "Scrolled by (0, 0) — nothing sent." }
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .line,
                                  wheelCount: 2, wheel1: Int32(clamping: dy),
                                  wheel2: Int32(clamping: dx), wheel3: 0) else {
            return "❌ Failed to create scroll event."
        }
        event.post(tap: .cghidEventTap)
        return "Scrolled by (\(dx), \(dy))"
    }

    /// ANSI-US layout virtual key codes plus named keys.
    private static let specialKeyCodes: [String: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17,
        "=": 0x18, "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D,
        "]": 0x1E, "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23,
        "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A,
        ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F,
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
        "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
        "command": 0x37, "cmd": 0x37, "shift": 0x38, "option": 0x3A, "alt": 0x3A,
        "control": 0x3B, "ctrl": 0x3B,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E
    ]

    private static let modifierKeyCodes: [String: CGKeyCode] = [
        "command": 0x37, "cmd": 0x37, "shift": 0x38,
        "option": 0x3A, "alt": 0x3A, "control": 0x3B, "ctrl": 0x3B
    ]

    private static let modifierFlags: [String: CGEventFlags] = [
        "command": .maskCommand, "cmd": .maskCommand,
        "shift": .maskShift,
        "option": .maskAlternate, "alt": .maskAlternate,
        "control": .maskControl, "ctrl": .maskControl
    ]

    public func runLoop(
        goal: String,
        decisionProvider: @Sendable @escaping (String, [ComputerUseStep]) async throws -> ComputerAction,
        watchdog: TurnWatchdog? = nil,
        autoApprove: Bool = false,
        onUpdate: @escaping (ComputerUseStep) -> Void
    ) async throws -> String {
        isRunning = true
        defer { isRunning = false }

        history.removeAll()

        let threadId = UUID().uuidString
        watchdog?.watch(threadId: threadId, botId: "computer_use")

        var currentTurn = 0
        while currentTurn < maxTurns {
            let action = try await decisionProvider(goal, history)
            
            switch action {
            case .click, .doubleClick, .type, .keyCombo, .scroll, .openApp:
                let verdict = ApprovalPolicy.verdict(
                    tool: "computer_use",
                    summary: action.humanReadableSummary,
                    autoApprove: autoApprove,
                    localScope: true
                )
                if verdict.approve == nil {
                    watchdog?.settle(threadId: threadId)
                    throw NSError(
                        domain: "ComputerUseAgent", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Action requires user approval: \(action.humanReadableSummary)"]
                    )
                }
            default:
                break
            }

            let observation = try await executeAction(action)
            let step = ComputerUseStep(turn: currentTurn, action: action, observation: observation)
            history.append(step)
            onUpdate(step)

            watchdog?.touch(threadId: threadId)

            if case .finish(let result) = action {
                watchdog?.settle(threadId: threadId)
                return result
            }
            if case .fail(let reason) = action {
                watchdog?.settle(threadId: threadId)
                throw NSError(domain: "ComputerUseAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
            }

            currentTurn += 1
        }

        watchdog?.settle(threadId: threadId)
        throw NSError(domain: "ComputerUseAgent", code: -2, userInfo: [NSLocalizedDescriptionKey: "Max turns reached without completion"])
    }

    public func runLoop(goal: String, onUpdate: @escaping (ComputerUseStep) -> Void) async throws -> String {
        return try await runLoop(
            goal: goal,
            decisionProvider: { goal, _ in .finish(result: "Goal achieved: \(goal)") },
            onUpdate: onUpdate
        )
    }
}
