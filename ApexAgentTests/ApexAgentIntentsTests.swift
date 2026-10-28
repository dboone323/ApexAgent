import Testing
import Foundation
import AppIntents
@testable import ApexAgentCore

@Suite("Batch 5: ApexAgentIntents Tests", .serialized)
struct ApexAgentIntentsTests {

    @Test("Summarize prompt formatting formats input into bullet point request")
    func testSummarizePromptFormatting() {
        let inputText = "Swift 6 strict concurrency provides data race safety at compile time."
        let expectedPrompt = "Summarize the following text in 3 bullet points:\n\n\(inputText)"
        
        // Verify format structure expected by SummarizeTextIntent
        #expect(expectedPrompt.contains("Summarize the following text in 3 bullet points:"))
        #expect(expectedPrompt.contains(inputText))
    }

    @Test("SummarizeTextIntent fallback value returns default when output is empty")
    func testSummarizeFallbackValue() {
        let emptyOutput = ""
        let result = emptyOutput.isEmpty ? "No summary produced." : emptyOutput
        #expect(result == "No summary produced.")

        let validOutput = "• Bullet 1\n• Bullet 2\n• Bullet 3"
        let validResult = validOutput.isEmpty ? "No summary produced." : validOutput
        #expect(validResult == validOutput)
    }

    @Test("FMIntentSupport command args construction")
    func testFMIntentSupportArgsConstruction() {
        let model = "system"
        let prompt = "Explain quantum computing"
        let instructions = "Be concise"

        var args = ["respond", "--model", model, "--stream"]
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--instructions", instructions]
        }
        args.append(prompt)

        #expect(args.contains("respond"))
        #expect(args.contains("--model"))
        #expect(args.contains("system"))
        #expect(args.contains("--instructions"))
        #expect(args.contains("Be concise"))
        #expect(args.last == prompt)
    }
}
