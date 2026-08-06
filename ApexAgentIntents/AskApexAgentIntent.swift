import AppIntents

/// Ask the on-device Apple Foundation Model a question, via ApexAgent's
/// `fm`-backed local inference. Exposes ApexAgent to Siri and Shortcuts.
struct AskApexAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask ApexAgent"
    static let description = IntentDescription("Ask the on-device Apple model a question through ApexAgent.")

    @Parameter(title: "Question", description: "What you want to ask.")
    var question: String

    @Parameter(title: "Use Cloud Compute", description: "Use the Private Cloud Compute server model instead of on-device.", default: false)
    var usePCC: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let model = usePCC ? "pcc" : "system"
        let answer = try await FMIntentSupport.runFM(prompt: question, model: model)
        return .result(value: answer.isEmpty ? "No response from the model." : answer)
    }
}
