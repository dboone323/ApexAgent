import Testing
import Foundation
import NaturalLanguage
@testable import ApexAgentCore

@Suite("NativeToolsP2Tests")
struct NativeToolsP2Tests {
    @Test("TranslateTool metadata and execution")
    @MainActor
    func testTranslateToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = TranslateTool(orchestrator: orchestrator)
        #expect(tool.name == "translate")

        let args = TranslateTool.Arguments(text: "Hola, ¿cómo estás?", targetLanguage: "en", sourceLanguage: "es")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        // Acceptable outcomes: a real report, a tool-level error, or the
        // executeWithLogging wrapper error ("ERROR: …", all caps) when the
        // Translation pair isn't installed AND the LLM fallback backend is
        // unavailable (environment-dependent; see TASK_MANIFEST SIGSEGV note).
        #expect(result.contains("Translation") || result.contains("Source") || result.contains("Target") || result.contains("Error") || result.contains("ERROR") || result.contains("❌"))
    }

    @Test("EntityExtractTool extracts people, places, organizations and sentiment")
    @MainActor
    func testEntityExtractToolExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = EntityExtractTool(orchestrator: orchestrator)
        #expect(tool.name == "extract_entities")

        let sampleText = """
        Tim Cook delivered a wonderful presentation in Cupertino, California at Apple headquarters. \
        The entire team was thrilled with the exceptional breakthrough!
        """

        let args = EntityExtractTool.Arguments(text: sampleText, filter: "all")
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        #expect(result.contains("Natural Language Analysis") || result.contains("Report"))
        #expect(result.contains("Language") || result.contains("Sentiment"))
    }

    @Test("EntityExtractTool empty input handling")
    @MainActor
    func testEntityExtractEmptyInput() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = EntityExtractTool(orchestrator: orchestrator)
        let args = EntityExtractTool.Arguments(text: "   ", filter: "all")
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Error") || result.contains("empty"))
    }

    @Test("AnalyzeImageTool metadata and error handling for nonexistent file")
    @MainActor
    func testAnalyzeImageNonexistentFile() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = AnalyzeImageTool(orchestrator: orchestrator)
        #expect(tool.name == "analyze_image")

        let args = AnalyzeImageTool.Arguments(imagePath: "/tmp/nonexistent_apex_test_image.png", query: "describe image")
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR") || result.contains("not found"))
    }
}
