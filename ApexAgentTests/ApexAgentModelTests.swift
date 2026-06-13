import XCTest
import FoundationModels
import SwiftData
@testable import ApexAgent

final class ApexAgentModelTests: XCTestCase {

    func testOllamaModelInitialization() {
        let url = URL(string: "http://localhost:11434")!
        let model = LocalOllamaLanguageModel(hostURL: url)
        XCTAssertEqual(model.hostURL, url)
        let caps = model.capabilities
        XCTAssertNotNil(caps)
    }

    func testGeminiModelInitialization() {
        let model = CloudGeminiLanguageModel(apiKey: "fake-api-key")
        XCTAssertEqual(model.apiKey, "fake-api-key")
        let caps = model.capabilities
        XCTAssertNotNil(caps)
    }

    func testLocalOllamaModelHostURLRoundTrip() {
        let alternate = URL(string: "http://127.0.0.1:11434")!
        let model = LocalOllamaLanguageModel(hostURL: alternate)
        XCTAssertEqual(model.hostURL, alternate)
    }

    func testCloudGeminiModelAPIKeyStored() {
        let key = "fake-key-" + UUID().uuidString
        let model = CloudGeminiLanguageModel(apiKey: key)
        XCTAssertEqual(model.apiKey, key)
    }

    @MainActor
    func testUpdaterControllerSharedInstance() {
        XCTAssertNotNil(UpdaterController.shared)
    }
    
    @MainActor
    func testUpdaterControllerCheckForUpdatesDoesNotThrow() async {
        do {
            try await UpdaterController.shared.checkForUpdates()
        } catch {
            XCTFail("checkForUpdates threw error: \(error)")
        }
    }

    @MainActor
    func testScreenStreamer() async {
        let streamer = ScreenStreamer.shared
        XCTAssertNotNil(streamer)
        
        // SCStream requires system permissions, so startCapture may fail to connect,
        // but it should not crash.
        await streamer.startCapture()
        
        // Stop capture to clean up state
        streamer.stopCapture()
        XCTAssertNil(streamer.getLatestFrame())
    }

    @MainActor
    func testAgentEngineToolSchemas() {
        let schemas = getParsedSchemas()
        XCTAssertFalse(schemas.isEmpty)
        XCTAssertTrue(schemas.contains { $0["name"] as? String == "run_shell_command" })
        XCTAssertTrue(schemas.contains { $0["name"] as? String == "read_file" })
        XCTAssertTrue(schemas.contains { $0["name"] as? String == "write_file" })
        
        let geminiDecls = getParsedGeminiFunctionDeclarations()
        XCTAssertFalse(geminiDecls.isEmpty)
        XCTAssertTrue(geminiDecls.contains { $0["name"] as? String == "run_shell_command" })
        
        let schemasJSON = getParsedSchemasJSONData()
        XCTAssertFalse(schemasJSON.isEmpty)
        
        let geminiJSON = getParsedGeminiFunctionDeclarationsJSONData()
        XCTAssertFalse(geminiJSON.isEmpty)
    }

    @MainActor
    func testMCPManagerConfiguration() async {
        let manager = MCPManager.shared
        XCTAssertNotNil(manager)
        
        let originalCount = manager.servers.count
        
        let newConfig = MCPServerConfig(
            name: "Test Server 123",
            command: "echo",
            arguments: ["hello"]
        )
        
        manager.addServer(newConfig)
        XCTAssertEqual(manager.servers.count, originalCount + 1)
        XCTAssertTrue(manager.servers.contains { $0.name == "Test Server 123" })
        
        let client = manager.getClient(for: newConfig)
        XCTAssertEqual(client.serverName, "Test Server 123")
        
        manager.removeServer(id: newConfig.id)
        XCTAssertEqual(manager.servers.count, originalCount)
        XCTAssertFalse(manager.servers.contains { $0.name == "Test Server 123" })
        
        await manager.stopAll()
    }
}
