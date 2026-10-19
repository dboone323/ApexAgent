import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ToolSchemasTests") final class ToolSchemasTests {
    
    @MainActor
    @Test func testToolSchemasLoadAndValidation() {
        let schemas = getParsedSchemas()
        #expect(!schemas.isEmpty, "Tool schemas should not be empty")
        
        for schema in schemas {
            guard let name = schema["name"] as? String, !name.isEmpty else {
                Issue.record("Schema is missing name or name is empty: \(schema)")
                continue
            }
            guard let description = schema["description"] as? String, !description.isEmpty else {
                Issue.record("Schema \(name) is missing description or description is empty")
                continue
            }
            
            // Check that parameters structure exists if specified
            if let parameters = schema["parameters"] as? [String: Any] {
                #expect(parameters["type"] != nil, "Schema \(name) has parameters but is missing type")
            }
        }
    }
    
    @MainActor
    @Test func testGeminiFunctionDeclarationsConversion() {
        let decls = getParsedGeminiFunctionDeclarations()
        #expect(!decls.isEmpty, "Gemini declarations should not be empty")
        
        for decl in decls {
            if let parameters = decl["parameters"] as? [String: Any],
               let type = parameters["type"] as? String {
                #expect(type == type.uppercased(), "Gemini parameter type must be uppercase")
            }
        }
    }
    
    @MainActor
    @Test func testDumpToolSchemas() throws {
        let orchestrator = AgentOrchestrator()
        let tools = orchestrator.toolDispatchEngine.buildAllTools(orchestrator: orchestrator, botManager: nil)
        #expect(tools.count == 78, "Must register all 78 native tools")

        var allSchemas: [[String: Any]] = []
        for tool in tools {
            if let jsonStr = tool.schemaJSON,
               let data = jsonStr.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                allSchemas.append(dict)
            }
        }
        #expect(allSchemas.count == 78, "Every registered tool must generate valid schema JSON")

        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceFile = projectDir
            .appendingPathComponent("ApexAgent")
            .appendingPathComponent("Resources")
            .appendingPathComponent("ToolSchemas.json")
        if FileManager.default.fileExists(atPath: resourceFile.path) {
            let data = try JSONSerialization.data(withJSONObject: allSchemas, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resourceFile)
        }
    }
}
