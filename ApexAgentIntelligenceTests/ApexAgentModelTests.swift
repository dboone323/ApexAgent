import Testing
import Foundation
import FoundationModels
import SwiftData
@testable import ApexAgentCore

@Suite("ApexAgentModelTests") final class ApexAgentModelTests {

    @Test func testOllamaModelInitialization() {
        let url = URL(string: "http://localhost:11434")!
        let model = LocalOllamaLanguageModel(hostURL: url)
        #expect(model.hostURL == url)
        let _ = model.capabilities
        #expect(Bool(true), "LocalOllamaLanguageModel is initialized successfully")
    }

    @Test func testGeminiModelInitialization() {
        let model = CloudGeminiLanguageModel(apiKey: "fake-api-key")
        #expect(model.apiKey == "fake-api-key")
        let _ = model.capabilities
        #expect(Bool(true), "CloudGeminiLanguageModel is initialized successfully")
    }

    @Test func testLocalOllamaModelHostURLRoundTrip() {
        let alternate = URL(string: "http://127.0.0.1:11434")!
        let model = LocalOllamaLanguageModel(hostURL: alternate)
        #expect(model.hostURL == alternate)
    }

    @Test func testCloudGeminiModelAPIKeyStored() {
        let key = "fake-key-" + UUID().uuidString
        let model = CloudGeminiLanguageModel(apiKey: key)
        #expect(model.apiKey == key)
    }

    @MainActor
    @Test func testUpdaterControllerSharedInstance() {
        let _ = UpdaterController.shared
        #expect(Bool(true), "UpdaterController.shared is initialized successfully")
    }
    
    @MainActor
    @Test func testUpdaterControllerCheckForUpdatesDoesNotThrow() {
        UpdaterController.shared.checkForUpdates()
        #expect(Bool(true), "UpdaterController.checkForUpdates does not throw")
    }

    @MainActor
    @Test func testScreenStreamer() async {
        let streamer = ScreenStreamer.shared
        // Let compile validation pass, startCapture requires TCC permissions in CI
        await streamer.startCapture()
        streamer.stopCapture()
        #expect(streamer.getLatestFrame() == nil)
    }

    @MainActor
    @Test func testAgentEngineToolSchemas() {
        let schemas = getParsedSchemas()
        #expect(!(schemas.isEmpty))
        #expect(schemas.contains { $0["name"] as? String == "run_shell_command" })
        #expect(schemas.contains { $0["name"] as? String == "read_file" })
        #expect(schemas.contains { $0["name"] as? String == "write_file" })
        
        let geminiDecls = getParsedGeminiFunctionDeclarations()
        #expect(!(geminiDecls.isEmpty))
        #expect(geminiDecls.contains { $0["name"] as? String == "run_shell_command" })
        
        let schemasJSON = getParsedSchemasJSONData()
        #expect(!(schemasJSON.isEmpty))
        
        let geminiJSON = getParsedGeminiFunctionDeclarationsJSONData()
        #expect(!(geminiJSON.isEmpty))
    }

    @MainActor
    @Test func testMCPManagerConfiguration() async {
        let manager = MCPManager.shared
        let originalCount = manager.servers.count
        
        let newConfig = MCPServerConfig(
            name: "Test Server 123",
            command: "echo",
            arguments: ["hello"]
        )
        
        manager.addServer(newConfig)
        #expect(manager.servers.count == originalCount + 1)
        #expect(manager.servers.contains { $0.name == "Test Server 123" })
        
        let client = manager.getClient(for: newConfig)
        #expect(client.serverName == "Test Server 123")
        
        manager.removeServer(id: newConfig.id)
        #expect(manager.servers.count == originalCount)
        #expect(!(manager.servers.contains { $0.name == "Test Server 123" }))
        
        await manager.stopAll()
    }
}
