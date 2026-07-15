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
    let description = "Performs UI automation actions on the active application window using accessibility (AXUIElement) APIs. Requires Accessibility permissions."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The action to perform: 'list_elements', 'click', 'set_text', 'focus'")
        var action: String
        
        @Guide(description: "The registry ID of the element (e.g. 'elem_1') - required for click, set_text, focus")
        var elementId: String?
        
        @Guide(description: "The text value to enter - required for set_text")
        var textValue: String?
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
                    let axWindow = windowElement as! AXUIElement
                    var output = "UI Elements in active window of \(frontmostApp.localizedName ?? ""):\n"
                    output += traverse(element: axWindow, depth: 0, maxDepth: 15, conversationId: conversationId)
                    return output
                    
                case "click":
                    guard let elementId = arguments.elementId else {
                        return "ERROR: elementId is required for click action."
                    }
                    guard let element = UIRegistry.shared.get(elementId, for: conversationId) else {
                        return "ERROR: Element \(elementId) not found in registry. Run list_elements first to refresh."
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
                        return "✅ Successfully set text on \(elementId) to '\(textValue)'"
                    } else {
                        return "ERROR: Failed to set text value: error \(err.rawValue)"
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
    private func traverse(element: AXUIElement, depth: Int, maxDepth: Int = 15, conversationId: UUID) -> String {
        guard depth <= maxDepth else { return "" }
        
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
        for child in children {
            output += traverse(element: child, depth: depth + 1, maxDepth: maxDepth, conversationId: conversationId)
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
}
