import Foundation
import FoundationModels
import AppKit
import ApplicationServices

struct AccessibilityOmniTargeter: Tool {
    let orchestrator: AgentOrchestrator
    
    let name = "ax_target_element"
    let description = "Builds a semantic index of every interactive element in the frontmost (or named) application window using the macOS Accessibility tree. Returns a numbered list like '[#1 Button Build, #2 TextField Filter...]'. Bots can then act on elements by their index using control_accessibility. Requires Accessibility permission."
    
    @Generable struct Arguments: Decodable {
        let appName: String?
        let filterRoles: String?
        let maxDepth: Int?
    }
    
    func call(arguments: Arguments) async throws -> String {
        return await Task { @MainActor in
            guard AXIsProcessTrusted() else {
                return "ERROR: Accessibility permissions not granted. Please enable in System Settings -> Privacy & Security -> Accessibility."
            }
            
            let ws = NSWorkspace.shared
            var targetApp: NSRunningApplication?
            
            if let appName = arguments.appName, !appName.isEmpty {
                targetApp = ws.runningApplications.first(where: { ($0.localizedName ?? "").lowercased() == appName.lowercased() })
            } else {
                targetApp = ws.frontmostApplication
            }
            
            guard let app = targetApp else {
                return "ERROR: Could not find target application."
            }
            
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var frontWindowRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &frontWindowRef)
            
            let targetElement: AXUIElement
            if err == .success, let frontWindow = frontWindowRef, CFGetTypeID(frontWindow) == AXUIElementGetTypeID() {
                targetElement = unsafeBitCast(frontWindow, to: AXUIElement.self)
            } else {
                targetElement = appElement
            }
            
            let maxDepth = arguments.maxDepth ?? 6
            let cappedDepth = min(maxDepth, 10)
            
            var filterRolesArray: [String]?
            if let filterRoles = arguments.filterRoles, !filterRoles.isEmpty {
                filterRolesArray = filterRoles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            
            var output = ""
            var remaining = 500
            let conversationId = UUID()
            
            UIRegistry.shared.clear(for: conversationId)
            
            @MainActor func traverse(element: AXUIElement, depth: Int) {
                guard depth <= cappedDepth, remaining > 0 else { return }
                remaining -= 1
                
                var roleRef: CFTypeRef?
                var titleRef: CFTypeRef?
                var valueRef: CFTypeRef?
                
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
                
                let role = roleRef as? String ?? "Unknown"
                let title = titleRef as? String ?? ""
                let valueStr = (valueRef as? String) ?? (valueRef as? NSNumber)?.stringValue ?? ""
                
                let isInteractive: Bool
                if let filters = filterRolesArray {
                    isInteractive = filters.contains(role)
                } else {
                    let defaultRoles = [
                        "AXButton", "AXTextField", "AXTextArea", "AXCheckBox", 
                        "AXRadioButton", "AXPopUpButton", "AXMenuItem", 
                        "AXLink", "AXSlider", "AXComboBox", "AXSearchField", "AXStaticText"
                    ]
                    isInteractive = defaultRoles.contains(role)
                }
                
                if isInteractive {
                    let idStr = UIRegistry.shared.register(element, for: conversationId)
                    var line = "[\(idStr) \(role) \"\(title)\""
                    if !valueStr.isEmpty {
                        line += " (value: '\(valueStr.prefix(50))')"
                    }
                    line += "]\n"
                    output += line
                }
                
                var childrenRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                   let children = childrenRef as? [AXUIElement] {
                    for child in children {
                        traverse(element: child, depth: depth + 1)
                    }
                }
            }
            
            traverse(element: targetElement, depth: 0)
            
            if output.isEmpty {
                return "No interactive elements found."
            }
            
            output += "\nUse control_accessibility with elementId 'elem_1', 'elem_2', etc."
            
            return output
        }.value
    }
}
