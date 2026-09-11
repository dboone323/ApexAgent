import AppKit

@MainActor
final class WritingToolsSupport: NSObject {
    static let shared = WritingToolsSupport()
    
    private override init() {}
    
    static func register() {
        guard #available(macOS 15.0, *) else {
            return
        }
        guard let app = NSApplication.shared as NSApplication? else {
            return
        }
        app.servicesProvider = shared
        let pasteboardType = NSPasteboard.PasteboardType.string
        app.registerServicesMenuSendTypes([pasteboardType], returnTypes: [pasteboardType])
    }
}

extension WritingToolsSupport {
    @objc
    func handleWritingToolsRequest(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string) else {
            return
        }
        let orchestrator = MCPManager.shared.orchestrator

        guard APEXWritingToolsIntegration.shared.processText(text, using: orchestrator) else {
            error.pointee = "Failed to process Writing Tools request"
            return
        }
    }
}

struct APEXWritingToolsIntegration {
    static let shared = APEXWritingToolsIntegration()
    private init() {}

    nonisolated func processText(_ text: String, using orchestrator: AgentOrchestrator) -> Bool {
        guard !text.isEmpty else {
            return false
        }

        Task { @MainActor in
            orchestrator.sendMessage("Polish and refine the following text while preserving tone and meaning:\n\n\(text)")
        }

        return true
    }
}
