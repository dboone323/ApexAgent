import Foundation
import FoundationModels

// MARK: - Computer Use Tool (live desktop input via CGEvent synthesis)

/// Exposes ComputerUseAgent's real mouse/keyboard synthesis to the model so a
/// session can act on the live desktop: click, type, key combos, scroll, open
/// apps. Pair with `inspect_ui` (observation) to target real elements instead
/// of guessed coordinates, and with ScreenshotTool/Vision OCR to verify the
/// UI state after each action. Every call flows through the confirmation gate
/// via `riskDescription`, so unattended turns still require explicit approval.
struct ComputerUseTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "computer_use"
    let description = """
    Performs live mouse and keyboard actions on the user's desktop: coordinate clicking, \
    typing text, pressing key combos (e.g. command+s), scrolling, and opening applications. \
    Prefer 'control_accessibility' ('inspect_ui' action) FIRST to read the target app's AX \
    outline and pick exact element coordinates; re-inspect or screenshot after acting to \
    verify the expected change happened. Use this tool for raw input that AX element \
    actions cannot express (key shortcuts, scrolling, non-accessible UI). Requires \
    Accessibility permission. At most one desktop input action per call.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action: 'click', 'double_click', 'type', 'key', 'scroll', 'open_app', or 'wait'.")
        var action: String

        @Guide(description: "Screen X coordinate for click/double_click (from inspect_ui element frames).")
        var x: Int?

        @Guide(description: "Screen Y coordinate for click/double_click.")
        var y: Int?

        @Guide(description: "Text to type for the 'type' action.")
        var text: String?

        @Guide(description: "Space-separated key names for 'key', e.g. 'command+s', tokens: command/cmd, shift, option/alt, control/ctrl, letters, digits, return, tab, space, delete, escape, arrows, f1-f12.")
        var keys: String?

        @Guide(description: "Horizontal scroll lines for 'scroll' (positive scrolls right).")
        var deltaX: Int?

        @Guide(description: "Vertical scroll lines for 'scroll' (positive scrolls down).")
        var deltaY: Int?

        @Guide(description: "Bundle identifier for 'open_app' (e.g. 'com.apple.Safari').")
        var appName: String?

        @Guide(description: "Seconds to wait (max 30) for the 'wait' action.")
        var seconds: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(
            arguments: arguments,
            orchestrator: orchestrator,
            riskDescription: "Synthetic mouse/keyboard input on the live desktop (computer use)."
        ) {
            // Permission is checkable up front so the model gets a precise,
            // actionable message instead of a raw failure for any input action.
            func permissionBlocked(_ action: ComputerAction) -> String? {
                let needsInput: Bool = switch action {
                case .click, .doubleClick, .type, .keyCombo, .scroll: true
                default: false
                }
                if needsInput && !ComputerUseAgent.hasAccessibilityPermission {
                    return "🔒 Accessibility permission required for computer-use input. Enable ApexAgent in System Settings > Privacy & Security > Accessibility, then retry."
                }
                return nil
            }

            let computerAction: ComputerAction
            switch arguments.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
            case "click":
                guard let x = arguments.x, let y = arguments.y else {
                    return "❌ Error: 'click' requires x and y coordinates (inspect_ui gives element frames)."
                }
                computerAction = .click(x: x, y: y)
                await MainActor.run {
                    GhostCursorController.shared.showCursor(at: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    GhostCursorController.shared.animateClick()
                }
            case "double_click", "doubleclick":
                guard let x = arguments.x, let y = arguments.y else {
                    return "❌ Error: 'double_click' requires x and y coordinates."
                }
                computerAction = .doubleClick(x: x, y: y)
                await MainActor.run {
                    GhostCursorController.shared.showCursor(at: CGPoint(x: CGFloat(x), y: CGFloat(y)))
                    GhostCursorController.shared.animateClick()
                }
            case "type":
                guard let text = arguments.text, !text.isEmpty else {
                    return "❌ Error: 'type' requires non-empty text."
                }
                computerAction = .type(text: text)
            case "key", "keycombo", "keys":
                guard let keys = arguments.keys, !keys.isEmpty else {
                    return "❌ Error: 'key' requires keys, e.g. 'command+s'."
                }
                computerAction = .keyCombo(keys: keys.split(separator: " ").map(String.init))
            case "scroll":
                computerAction = .scroll(deltaX: arguments.deltaX ?? 0, deltaY: arguments.deltaY ?? 0)
            case "open_app":
                guard let appName = arguments.appName, !appName.isEmpty else {
                    return "❌ Error: 'open_app' requires an appName bundle identifier."
                }
                computerAction = .openApp(name: appName)
            case "wait":
                let seconds = min(max(arguments.seconds ?? 1.0, 0.1), 30)
                computerAction = .wait(seconds: seconds)
            default:
                return "⚠️ Unknown computer_use action '\(arguments.action)'. Available: 'click', 'double_click', 'type', 'key', 'scroll', 'open_app', 'wait'."
            }

            // Grab the MainActor-isolated singleton (hops off the tool's task
            // context); its async methods then hop back to the main actor.
            let agent = await MainActor.run { ComputerUseAgent.shared }

            if let blocked = permissionBlocked(computerAction) {
                return blocked
            }

            do {
                return try await agent.executeAction(computerAction)
            } catch {
                return "❌ Computer-use action failed: \(error.localizedDescription)"
            }
        }
    }
}
