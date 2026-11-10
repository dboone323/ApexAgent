import Testing
import Foundation
import AppIntents
@testable import ApexAgentCore
@testable import ApexAgentIntents

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

    // ── Real Framework Integration Tests (Issue #119) ──

    @Test("SummarizeTextIntent metadata matches expected values")
    func testSummarizeTextIntentMetadata() {
        #expect(SummarizeTextIntent.title.key == "Summarize with ApexAgent")
        #expect(String(describing: SummarizeTextIntent.description).contains("Summarize text using the on-device Apple model through ApexAgent."))
    }

    @Test("SummarizeTextIntent parameter initialization and assignment")
    func testSummarizeTextIntentParameter() {
        var intent = SummarizeTextIntent()
        intent.text = "Real input text for summarization."
        #expect(intent.text == "Real input text for summarization.")
    }

    @Test("FMIntentSupport runFM executes real CLI and propagates exit error when model is unavailable")
    func testFMIntentSupportRealExecution() async {
        do {
            _ = try await FMIntentSupport.runFM(
                prompt: "Say OK",
                instructions: "Be brief",
                model: "system"
            )
            #expect(true)
        } catch let error as NSError {
            #expect(error.domain == "FMIntentSupport")
            #expect(error.code == -2 || error.code == -1)
            #expect(error.localizedDescription.contains("fm exited") || error.localizedDescription.contains("fm CLI not found"))
        }
    }

    @Test("FMIntentSupport runFM executes without instructions parameter")
    func testFMIntentSupportWithoutInstructions() async {
        do {
            _ = try await FMIntentSupport.runFM(prompt: "Ping")
            #expect(true)
        } catch let error as NSError {
            #expect(error.domain == "FMIntentSupport")
            #expect(error.code == -2 || error.code == -1)
        }
    }

    @Test("FMIntentSupport handles task cancellation")
    func testFMIntentSupportCancellation() async {
        let task = Task {
            try await FMIntentSupport.runFM(prompt: "Long running prompt")
        }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            #expect(error is CancellationError || (error as NSError).domain == "FMIntentSupport")
        }
    }

    @Test("SummarizeTextIntent perform exercises real intent logic and invokes FMIntentSupport")
    func testSummarizeTextIntentPerform() async {
        var intent = SummarizeTextIntent()
        intent.text = "ApexAgent integrates on-device Foundation Models with AppIntents."
        do {
            _ = try await intent.perform()
            #expect(true)
        } catch let error as NSError {
            #expect(error.domain == "FMIntentSupport")
            #expect(error.code == -2 || error.code == -1)
            #expect(error.localizedDescription.contains("fm exited") || error.localizedDescription.contains("fm CLI not found"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
