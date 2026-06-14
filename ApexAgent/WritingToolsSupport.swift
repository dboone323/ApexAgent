import AppKit
import UniformTypeIdentifiers

struct WritingToolsSupport {
    static func register() {
        guard #available(macOS 15.0, *) else {
            return
        }
        NSApp.servicesProvider = self
        let pasteboardType = UTType.text.identifier
        NSApp.registerServicesMenu(type: [pasteboardType], sendTypes: [:], returnTypes: [pasteboardType])
    }
}

extension WritingToolsSupport {
    @objc
    static func handleWritingToolsRequest(pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = pasteboard.string(forType: .text),
              let orchestrator = AppDelegate.getSharedOrchestrator() else {
            return
        }

        guard APEXWritingToolsIntegration.shared.processText(text, using: orchestrator) else {
            error.pointee = "Failed to process Writing Tools request"
        }
    }
}

final class APEXWritingToolsIntegration {
    static let shared = APEXWritingToolsIntegration()
    private let processQueue = DispatchQueue(label: "com.dboone323.apex.writingtools")

    private init() {}

    func processText(_ text: String, using orchestrator: AgentOrchestrator) -> Bool {
        var success = true
        processQueue.async {
            let prompt = "Polish and refine the following text while preserving tone and meaning:\n\n\(text)"
            _ = orchestrator.sendMessage(prompt)
        }
        return success
    }
}

extension AppDelegate {
    static func configureWritingTools() {
        WritingToolsSupport.register()
    }
}
