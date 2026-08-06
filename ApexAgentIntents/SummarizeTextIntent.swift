import AppIntents

/// Summarize arbitrary text using the on-device Apple Foundation Model, exposed
/// to Siri and Shortcuts through ApexAgent.
struct SummarizeTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize with ApexAgent"
    static let description = IntentDescription("Summarize text using the on-device Apple model through ApexAgent.")

    @Parameter(title: "Text", description: "The text to summarize.")
    var text: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prompt = "Summarize the following text in 3 bullet points:\n\n\(text)"
        let summary = try await FMIntentSupport.runFM(prompt: prompt, model: "system")
        return .result(value: summary.isEmpty ? "No summary produced." : summary)
    }
}
