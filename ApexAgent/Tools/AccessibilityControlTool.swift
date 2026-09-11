import Foundation
import FoundationModels
import AppKit
import ApplicationServices

// MARK: - UI Registry for Accessibility Elements

@MainActor
class UIRegistry {
    static let shared = UIRegistry()
    private var elementsByConversation: [UUID: [String: AXUIElement]] = [:]
    private var nextIdByConversation: [UUID: Int] = [:]
    
    func clear(for conversationId: UUID) {
        elementsByConversation[conversationId] = [:]
        nextIdByConversation[conversationId] = 1
    }
    
    func clearAll() {
        elementsByConversation.removeAll()
        nextIdByConversation.removeAll()
    }
    
    func register(_ element: AXUIElement, for conversationId: UUID) -> String {
        let nextId = nextIdByConversation[conversationId] ?? 1
        let id = "elem_\(nextId)"
        
        var dict = elementsByConversation[conversationId] ?? [:]
        dict[id] = element
        elementsByConversation[conversationId] = dict
        
        nextIdByConversation[conversationId] = nextId + 1
        return id
    }
    
    func get(_ id: String, for conversationId: UUID) -> AXUIElement? {
        return elementsByConversation[conversationId]?[id]
    }
}

// MARK: - Accessibility Control Tool

struct AccessibilityControlTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "control_accessibility"
    let description = """
    Performs UI automation actions on the active application window using accessibility (AXUIElement) APIs, and provides observation capabilities to inspect the live UI tree with elements' roles, titles, values, and positions. Requires Accessibility permissions.
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The action to perform: 'inspect_ui', 'list_elements', 'click', 'set_text', 'focus'")
        var action: String
        
        @Guide(description: "The registry ID of the element (e.g. 'elem_1') - required for click, set_text, focus")
        var elementId: String?
        
        @Guide(description: "The text value to enter - required for set_text")
        var textValue: String?

        @Guide(description: "Name of the running app to inspect (e.g. 'Safari'). Defaults to the frontmost app.")
        var appName: String?

        @Guide(description: "Bundle identifier of the running app to inspect. Takes precedence over appName.")
        var bundleId: String?

        @Guide(description: "Maximum tree depth to traverse (default 8, capped at 12).")
        var maxDepth: Int?

        @Guide(description: "Include element values such as text field contents (default true).")
        var includeValues: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: "Controlling system user interface via Accessibility APIs") {
            if !AXIsProcessTrusted() {
                return "ERROR: Accessibility permissions are disabled. Please enable accessibility access for Apex Agent in System Settings > Privacy & Security > Accessibility."
            }
            
            let orchestrator = await self.orchestrator.orchestrator
            
            let conversationId = await MainActor.run {
                orchestrator.currentConversation?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            }
            
            return await MainActor.run {
                switch arguments.action {
                case "inspect_ui":
                    let depthLimit = min(max(arguments.maxDepth ?? 8, 1), 12)
                    let includeValues = arguments.includeValues ?? true
                    guard let target = Self.locateApp(bundleId: arguments.bundleId, appName: arguments.appName) else {
                        return "❌ Could not locate a matching running application. Check 'appName' or 'bundleId'."
                    }
                    let appElement = AXUIElementCreateApplication(target.pid)
                    var lines: [String] = []
                    lines.append("🪟 **UI Outline — \(target.title)** (PID \(target.pid), depth ≤ \(depthLimit)):")
                    var remainingNodes = 150
                    Self.walk(element: appElement, depth: 0, maxDepth: depthLimit, includeValues: includeValues, remaining: &remainingNodes, into: &lines, conversationId: conversationId)

                    if lines.count <= 1 {
                        return "⚠️ No accessible elements found for \(target.title). The app may expose no AX tree (e.g. non-standard rendering)."
                    }
                    if remainingNodes <= 0 {
                        lines.append("… [outline truncated at 150 elements — narrow by increasing depth filtering or inspecting a specific app]")
                    }
                    return lines.joined(separator: "\n")
                    
                case "list_elements":
                    UIRegistry.shared.clear(for: conversationId)
                    guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
                        return "ERROR: No frontmost application found."
                    }
                    let pid = frontmostApp.processIdentifier
                    let appElement = AXUIElementCreateApplication(pid)
                    
                    var windowValue: AnyObject?
                    let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue)
                    guard err == .success, let windowElement = windowValue else {
                        return "ERROR: Could not fetch active window of application \(frontmostApp.localizedName ?? "")."
                    }
                    
                    guard CFGetTypeID(windowElement) == AXUIElementGetTypeID() else {
                        return "ERROR: Active window element is not of type AXUIElement."
                    }
                    let axWindow = unsafeBitCast(windowElement, to: AXUIElement.self)
                    var output = "UI Elements in active window of \(frontmostApp.localizedName ?? ""):\n"
                    var remaining = 100
                    output += traverse(element: axWindow, depth: 0, maxDepth: 8, remaining: &remaining, conversationId: conversationId)
                    return output
                    
                case "click":
                    guard let elementId = arguments.elementId else {
                        return "ERROR: elementId is required for click action."
                    }
                    guard let element = UIRegistry.shared.get(elementId, for: conversationId) else {
                        return "ERROR: Element \(elementId) not found in registry. Run list_elements first to refresh."
                    }
                    if let rect = Self.frame(of: element) {
                        let center = CGPoint(x: rect.midX, y: rect.midY)
                        GhostCursorController.shared.showCursor(at: center)
                        GhostCursorController.shared.animateClick()
                    }
                    let err = AXUIElementPerformAction(element, kAXPressAction as CFString)
                    if err == .success {
                        return "✅ Successfully clicked element \(elementId)"
                    } else {
                        return "ERROR: Failed to click element: error \(err.rawValue)"
                    }
                    
                case "set_text":
                    guard let elementId = arguments.elementId else {
                        return "ERROR: elementId is required for set_text action."
                    }
                    guard let textValue = arguments.textValue else {
                        return "ERROR: textValue is required for set_text action."
                    }
                    guard let element = UIRegistry.shared.get(elementId, for: conversationId) else {
                        return "ERROR: Element \(elementId) not found in registry. Run list_elements first to refresh."
                    }
                    let err = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, textValue as CFTypeRef)
                    if err == .success {
                        return "✅ Successfully set text on element \(elementId)"
                    } else {
                        return "ERROR: Failed to set text on element: error \(err.rawValue)"
                    }
                    
                case "focus":
                    guard let elementId = arguments.elementId else {
                        return "ERROR: elementId is required for focus action."
                    }
                    guard let element = UIRegistry.shared.get(elementId, for: conversationId) else {
                        return "ERROR: Element \(elementId) not found in registry. Run list_elements first to refresh."
                    }
                    let err = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, true as CFTypeRef)
                    if err == .success {
                        return "✅ Successfully focused element \(elementId)"
                    } else {
                        return "ERROR: Failed to focus element: error \(err.rawValue)"
                    }
                    
                default:
                    return "ERROR: Unknown action '\(arguments.action)'. Supported: list_elements, click, set_text, focus"
                }
            }
        }
    }
    
    @MainActor
    private func traverse(element: AXUIElement, depth: Int, maxDepth: Int = 8, remaining: inout Int, conversationId: UUID) -> String {
        guard depth <= maxDepth, remaining > 0 else { return "" }
        remaining -= 1
        
        var output = ""
        let role = getAttribute(element, attribute: kAXRoleAttribute) as? String ?? "Unknown"
        let title = getAttribute(element, attribute: kAXTitleAttribute) as? String ?? ""
        let description = getAttribute(element, attribute: kAXDescriptionAttribute) as? String ?? ""
        let value = getValue(element) ?? ""
        
        let isInteractive = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", 
            "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuItem", 
            "AXLink", "AXRadioGroup", "AXSlider", "AXMenuButton"
        ].contains(role)
        
        var label = title
        if label.isEmpty {
            label = description
        }
        
        var line = ""
        let indent = String(repeating: "  ", count: depth)
        if isInteractive {
            let id = UIRegistry.shared.register(element, for: conversationId)
            line = "\(indent)[\(id)] \(role) name: \"\(label)\" value: \"\(value)\"\n"
        } else if !label.isEmpty {
            line = "\(indent)\(role) name: \"\(label)\"\n"
        }
        
        output += line
        
        let children = getChildren(element)
        for child in children where remaining > 0 {
            output += traverse(element: child, depth: depth + 1, maxDepth: maxDepth, remaining: &remaining, conversationId: conversationId)
        }
        
        return output
    }
    
    private func getAttribute(_ element: AXUIElement, attribute: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return err == .success ? value : nil
    }
    
    private func getValue(_ element: AXUIElement) -> String? {
        guard let val = getAttribute(element, attribute: kAXValueAttribute) else { return nil }
        if let str = val as? String { return str }
        if let num = val as? NSNumber { return num.stringValue }
        return nil
    }
    
    private func getChildren(_ element: AXUIElement) -> [AXUIElement] {
        guard let val = getAttribute(element, attribute: kAXChildrenAttribute) else { return [] }
        return val as? [AXUIElement] ?? []
    }

    private struct TargetApp {
        let pid: pid_t
        let title: String
    }

    private static func locateApp(bundleId: String?, appName: String?) -> TargetApp? {
        let ws = NSWorkspace.shared
        if let bid = bundleId?.lowercased(), !bid.isEmpty,
           let app = ws.runningApplications.first(where: { $0.bundleIdentifier?.lowercased() == bid }) {
            return TargetApp(pid: app.processIdentifier, title: app.localizedName ?? bid)
        }
        if let name = appName?.lowercased(), !name.isEmpty,
           let app = ws.runningApplications.first(where: { ($0.localizedName ?? "").lowercased() == name }) {
            return TargetApp(pid: app.processIdentifier, title: app.localizedName ?? name)
        }
        if let frontmost = ws.frontmostApplication {
            return TargetApp(pid: frontmost.processIdentifier, title: frontmost.localizedName ?? "frontmost app")
        }
        return nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = attribute(element, kAXPositionAttribute),
              let sizeRef = attribute(element, kAXSizeAttribute) else { return nil }
        guard CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(positionRef, to: AXValue.self)
        let sizeValue = unsafeDowncast(sizeRef, to: AXValue.self)
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    @MainActor
    private static func walk(element: AXUIElement, depth: Int, maxDepth: Int,
                             includeValues: Bool, remaining: inout Int, into lines: inout [String], conversationId: UUID) {
        guard depth <= maxDepth, remaining > 0 else { return }
        remaining -= 1

        let role = (attribute(element, kAXRoleAttribute) as? String) ?? "?"
        var description = role
        if let title = attribute(element, kAXTitleAttribute) as? String, !title.isEmpty {
            description += " '\(title.prefix(60))'"
        }
        if includeValues, let value = attribute(element, kAXValueAttribute) as? String,
           !value.isEmpty, role != "AXStaticText" || value.count <= 80 {
            description += " = \"\(value.prefix(80))\""
        }
        if let rect = frame(of: element) {
            description += " (\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))x\(Int(rect.height)))"
        }
        
        let isInteractive = [
            "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", 
            "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuItem", 
            "AXLink", "AXRadioGroup", "AXSlider", "AXMenuButton"
        ].contains(role)

        if isInteractive {
            let id = UIRegistry.shared.register(element, for: conversationId)
            description += " [\(id)]"
        }

        lines.append("\(String(repeating: "  ", count: depth))- \(description)")

        if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children where remaining > 0 {
                walk(element: child, depth: depth + 1, maxDepth: maxDepth,
                     includeValues: includeValues, remaining: &remaining, into: &lines, conversationId: conversationId)
            }
        }
    }
}
