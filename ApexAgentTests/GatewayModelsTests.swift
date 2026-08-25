import Testing
import Foundation
import SharedModels
@testable import ApexAgentCore

@Suite("GatewayModelsTests") final class GatewayModelsTests {
    
    @Test func testCodableToolEventSerialization() throws {
        let event = CodableToolEvent(
            toolName: "shell_command",
            status: "success",
            riskDescription: "Runs shell code",
            arguments: "{\"command\":\"ls\"}",
            result: "file1.txt\n"
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(event)
        let decoded = try decoder.decode(CodableToolEvent.self, from: data)
        
        #expect(decoded.toolName == "shell_command")
        #expect(decoded.status == "success")
        #expect(decoded.arguments == "{\"command\":\"ls\"}")
        #expect(decoded.result == "file1.txt\n")
    }
    
    @Test func testCodableChatMessageSerialization() throws {
        _ = CodableToolEvent(toolName: "list_dir", status: "success", riskDescription: nil, arguments: "", result: "")
        let msg = CodableChatMessage(
            role: CodableMessageRole.assistant,
            content: "Scanning complete",
            toolEvents: [
                CodableToolEvent(toolName: "list_dir", status: "success", riskDescription: nil, arguments: "", result: "")
            ]
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let data = try encoder.encode(msg)
        let decoded = try decoder.decode(CodableChatMessage.self, from: data)
        
        #expect(decoded.role == CodableMessageRole.assistant)
        #expect(decoded.content == "Scanning complete")
        #expect(decoded.toolEvents.count == 1)
    }
}
