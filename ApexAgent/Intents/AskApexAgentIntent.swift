import AppIntents
import Foundation

// MARK: - App Intents exposure (Siri / Shortcuts)
//
// Exposes ApexAgent's core action ("ask the agent a question / run a task") to
// Siri and the Shortcuts app. This is the AppIntents-era replacement for the
// deprecated INIntent-based wiring and is the supported way to surface agent
// actions per Apple's "Build intelligent Siri experiences with App Schemas"
// guidance.

@available(macOS 13.0, *)
struct AskApexAgentIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "Ask Apex Agent" }
    nonisolated static var description: IntentDescription { IntentDescription("Send a prompt to Apex Agent and get a response.") }

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Ask Apex Agent \(\.$prompt)")
    }

    @Parameter(title: "Prompt", description: "The question or task to send to Apex Agent.")
    var prompt: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntentError.emptyPrompt
        }

        let orchestrator = AppDelegate.sharedOrchestrator
        orchestrator.sendMessage(prompt)

        // Wait for the agent to finish generating (best-effort, bounded).
        var waited: UInt64 = 0
        let step: UInt64 = 100_000_000 // 0.1s
        let maxWait: UInt64 = 30 * 1_000_000_000 // 30s
        while orchestrator.isGenerating && waited < maxWait {
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }

        if let last = orchestrator.messages.last(where: { $0.role == .assistant }) {
            return .result(value: last.content)
        }
        return .result(value: "Apex Agent received your request but produced no response.")
    }

    enum IntentError: LocalizedError {
        case emptyPrompt
        var errorDescription: String? {
            switch self {
            case .emptyPrompt: return "The prompt was empty."
            }
        }
    }
}

@available(macOS 13.0, *)
struct ApexAgentShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskApexAgentIntent(),
            phrases: [
                "Ask ${applicationName} \\.$prompt",
                "Tell ${applicationName} \\.$prompt"
            ],
            shortTitle: "Ask Apex Agent",
            systemImageName: "bolt.fill"
        )
    }
}
