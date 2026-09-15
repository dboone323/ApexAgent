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
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.emptyPrompt
        }

        let orchestrator = AppDelegate.sharedOrchestrator
        let request = AgentRequest(
            senderIdentity: .intent(name: "AskApexAgent"),
            prompt: trimmed,
            toolCallingMode: orchestrator.toolCallingMode
        )

        let terminalState = await AgentRequestRouter.shared.route(
            request,
            history: orchestrator.messages,
            instructions: orchestrator.agentInstructions,
            orchestrator: orchestrator
        )

        return .result(value: terminalState.userFacingMessage)
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
