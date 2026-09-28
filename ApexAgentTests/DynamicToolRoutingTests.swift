import Testing
import Foundation
@testable import ApexAgentCore

// Conformer for testing the extension
private final class TestToolRouter: DynamicToolRouting {}

@Suite("DynamicToolRoutingTests") final class DynamicToolRoutingTests {
    @Test func testExecuteNonexistentDynamicToolReturnsError() async {
        let router = TestToolRouter()
        let result = await router.executeDynamicTool(name: "nonexistent_verification_tool", argumentsString: "{}")
        #expect(result.starts(with: "ERROR:"), "Executing a nonexistent dynamic tool must return an error result")
        #expect(result.contains("nonexistent_verification_tool"), "Error result must mention the requested tool name")
    }

    @Test func testLanguageModelExecutorSupportCheck() {
        let supported = isLanguageModelExecutorSupported()
        // The runtime symbol check must complete and return a boolean without crashing or throwing
        #expect(supported == true || supported == false)
    }
}
