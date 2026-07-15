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
    @Test func testDumpToolSchemas() {
        let orchestrator = AgentOrchestrator()
        let shellTool = ShellTool(orchestrator: orchestrator)
        let params = shellTool.parameters
        print("--- GenerationSchema type: \(type(of: params)) ---")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(params),
           let jsonStr = String(data: data, encoding: .utf8) {
            print("Serialized JSON schema:")
            print(jsonStr)
        } else {
            print("Failed to encode GenerationSchema data")
        }
    }
}
