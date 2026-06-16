import AppKit
import UniformTypeIdentifiers

@MainActor
final class WritingToolsSupport: NSObject {
    static let shared = WritingToolsSupport()
    
    private override init() {}
    
    static func register() {
        guard #available(macOS 15.0, *) else {
            return
        }
        NSApp.servicesProvider = shared
        let pasteboardType = NSPasteboard.PasteboardType.string
        NSApp.registerServicesMenuSendTypes([pasteboardType], returnTypes: [pasteboardType])
    }
}

extension WritingToolsSupport {
    @objc
    func handleWritingToolsRequest(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .string),
              let orchestrator = AppDelegate.getSharedOrchestrator() else {
            return
        }

        guard APEXWritingToolsIntegration.shared.processText(text, using: orchestrator) else {
            error.pointee = "Failed to process Writing Tools request"
            return
        }
    }
}

@MainActor
final class APEXWritingToolsIntegration {
    static let shared = APEXWritingToolsIntegration()
    private let processQueue = DispatchQueue(label: "com.dboone323.apex.writingtools")

    private init() {}

    func processText(_ text: String, using orchestrator: AgentOrchestrator) -> Bool {
        let success = true
        processQueue.async {
            let prompt = "Polish and refine the following text while preserving tone and meaning:\n\n\(text)"
            Task { @MainActor in
                orchestrator.sendMessage(prompt)
            }
        }
        return success
    }
}

extension AppDelegate {
    static func configureWritingTools() {
        WritingToolsSupport.register()
    }
}
