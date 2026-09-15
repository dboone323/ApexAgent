import XCTest
@testable import ApexAgentCore

@MainActor
final class EnterpriseSecurityTests: XCTestCase {
    
    override func setUp() async throws {
        // Clear audit chain for test isolation
        CryptographicAuditChain.shared.trimToLast(0)
    }

    func testAuditChainRecordAndVerify() async throws {
        let chain = CryptographicAuditChain.shared
        chain.record(toolName: "tool1", input: "in1", output: "out1", status: "success", botName: nil)
        chain.record(toolName: "tool2", input: "in2", output: "out2", status: "success", botName: nil)
        chain.record(toolName: "tool3", input: "in3", output: "out3", status: "success", botName: nil)
        
        let isValid = chain.verifyChain()
        XCTAssertTrue(isValid)
        XCTAssertEqual(chain.entries.count, 3)
    }

    func testAuditChainExport() async throws {
        let chain = CryptographicAuditChain.shared
        chain.record(toolName: "exportTool", input: "in", output: "out", status: "success", botName: nil)
        
        let data = try chain.exportChain()
        let decoded = try JSONDecoder().decode([CryptographicAuditChain.AuditEntry].self, from: data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.toolName, "exportTool")
    }
    
    func testAuditChainTrimming() async throws {
        let chain = CryptographicAuditChain.shared
        for i in 1...10 {
            chain.record(toolName: "tool\(i)", input: "in", output: "out", status: "success", botName: nil)
        }
        
        XCTAssertEqual(chain.entries.count, 10)
        chain.trimToLast(5)
        XCTAssertEqual(chain.entries.count, 5)
        XCTAssertEqual(chain.entries.last?.toolName, "tool10")
        XCTAssertTrue(chain.verifyChain())
    }
    
    func testEphemeralTokenIssueAndConsume() async throws {
        let manager = EphemeralCapabilityManager.shared
        let token = manager.issueToken(for: "delete_file", botName: nil, ttlSeconds: 60.0)
        
        XCTAssertTrue(manager.hasValidToken(botName: nil, toolName: "delete_file"))
        
        let consumed = manager.consumeToken(id: token.id, toolName: "delete_file")
        XCTAssertTrue(consumed)
        
        let consumedAgain = manager.consumeToken(id: token.id, toolName: "delete_file")
        XCTAssertFalse(consumedAgain)
    }
    
    func testEphemeralTokenExpiry() async throws {
        let manager = EphemeralCapabilityManager.shared
        let token = manager.issueToken(for: "test_tool", botName: nil, ttlSeconds: 0.001)
        
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        XCTAssertTrue(token.isExpired)
        
        let consumed = manager.consumeToken(id: token.id, toolName: "test_tool")
        XCTAssertFalse(consumed)
    }
    
    func testEphemeralTokenRevokeAll() async throws {
        let manager = EphemeralCapabilityManager.shared
        _ = manager.issueToken(for: "run_shell_command", botName: nil, ttlSeconds: 60.0)
        _ = manager.issueToken(for: "run_shell_command", botName: nil, ttlSeconds: 60.0)
        _ = manager.issueToken(for: "run_shell_command", botName: nil, ttlSeconds: 60.0)
        
        manager.revokeAll(for: "run_shell_command")
        
        let tokens = manager.activeTokens.filter { $0.toolName == "run_shell_command" }
        XCTAssertTrue(tokens.isEmpty)
    }
    
    func testAuditChainTamperDetection() async throws {
        let chain = CryptographicAuditChain.shared
        chain.trimToLast(0)
        
        TestActivity.step("Record genuine entries") { _ in
            chain.record(toolName: "validTool1", input: "in1", output: "out1", status: "success", botName: nil)
            chain.record(toolName: "validTool2", input: "in2", output: "out2", status: "success", botName: nil)
            XCTAssertTrue(chain.verifyChain(), "Untampered chain must verify")
            XCTAssertTrue(chain.chainValid)
        }
        
        try TestActivity.step("Tamper with an entry and verify detection") { _ in
            let validData = try chain.exportChain()
            var decoded = try JSONDecoder().decode([CryptographicAuditChain.AuditEntry].self, from: validData)
            XCTAssertEqual(decoded.count, 2)
            
            // Mutate inputArguments of the first entry without updating its hash
            let tamperedEntry = CryptographicAuditChain.AuditEntry(
                id: decoded[0].id,
                timestamp: decoded[0].timestamp,
                toolName: decoded[0].toolName,
                inputArguments: "TAMPERED_INPUT_PAYLOAD",
                outputSummary: decoded[0].outputSummary,
                exitStatus: decoded[0].exitStatus,
                botName: decoded[0].botName,
                previousHash: decoded[0].previousHash,
                entryHash: decoded[0].entryHash
            )
            decoded[0] = tamperedEntry
            
            let tamperedData = try JSONEncoder().encode(decoded)
            let importedValid = try chain.importChain(from: tamperedData)
            XCTAssertFalse(importedValid, "Chain import must report invalid for tampered entry")
            XCTAssertFalse(chain.chainValid, "chainValid property must be false after tamper detection")
            XCTAssertFalse(chain.verifyChain(), "verifyChain must return false on tampered chain")
        }
    }
    
    func testEphemeralTokenConcurrentConsumption() async throws {
        let manager = EphemeralCapabilityManager.shared
        let token = manager.issueToken(for: "concurrent_tool", botName: "bot_a", ttlSeconds: 60.0)
        
        var consumeResults: [Bool] = []
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask { @MainActor in
                    manager.consumeToken(id: token.id, toolName: "concurrent_tool")
                }
            }
            for await result in group {
                consumeResults.append(result)
            }
        }
        
        TestActivity.step("Ensure token cannot be double-consumed under concurrency") { _ in
            let successCount = consumeResults.filter { $0 }.count
            XCTAssertEqual(successCount, 1, "Exactly one concurrent caller may consume the single-use token")
            XCTAssertFalse(manager.hasValidToken(botName: "bot_a", toolName: "concurrent_tool"))
        }
    }
    
    // MARK: - Stage 3: MicroVM & Sandbox Tests
    
    func testMicroVMConfigurationValidation() throws {
        let sandbox = VirtualizationMicroVMSandbox.shared
        guard sandbox.isHypervisorSupported else { return }
        
        let config = try sandbox.buildMicroVMConfiguration(cpuCount: 2, memoryBytes: 1024 * 1024 * 1024)
        XCTAssertEqual(config.cpuCount, 2)
        XCTAssertEqual(config.memorySize, 1024 * 1024 * 1024)
        XCTAssertFalse(config.entropyDevices.isEmpty, "MicroVM must configure entropy device for security")
        XCTAssertFalse(config.memoryBalloonDevices.isEmpty, "MicroVM must configure memory balloon device")
    }
    
    func testEphemeralSandboxExecution() async throws {
        let sandbox = VirtualizationMicroVMSandbox.shared
        let result = try await sandbox.executeInIsolatedSandbox(command: "echo 'apex_sandbox_test'")
        
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("apex_sandbox_test"))
        XCTAssertTrue(result.wasSandboxed)
        XCTAssertEqual(sandbox.activeSandboxCount, 0, "Sandbox count must return to 0 after rollback")
    }
    
    func testCapabilityTokenEnforcementInAgentSecurity() {
        let toolName = "run_shell_command"
        
        // 1. When strict mode is disabled (default), validateCapabilityToken returns true
        UserDefaults.standard.set(false, forKey: "apex.enterprise.strictCapabilityTokens")
        XCTAssertTrue(AgentSecurity.validateCapabilityToken(for: toolName, botName: nil))
        
        // 2. When strict mode is enabled, without token it returns false
        UserDefaults.standard.set(true, forKey: "apex.enterprise.strictCapabilityTokens")
        XCTAssertFalse(AgentSecurity.validateCapabilityToken(for: toolName, botName: nil))
        
        // 3. When token is issued, it returns true
        _ = EphemeralCapabilityManager.shared.issueToken(for: toolName, botName: nil, ttlSeconds: 60.0)
        XCTAssertTrue(AgentSecurity.validateCapabilityToken(for: toolName, botName: nil))
        
        // Cleanup
        EphemeralCapabilityManager.shared.revokeAll(for: toolName)
        UserDefaults.standard.set(false, forKey: "apex.enterprise.strictCapabilityTokens")
    }
}
