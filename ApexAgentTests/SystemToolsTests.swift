import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SystemToolsTests")
@MainActor
struct SystemToolsTests {

    @Test("AppleShortcutsTool list action executes or handles system shortcut environment cleanly")
    func testShortcutsToolList() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = AppleShortcutsTool(orchestrator: orchestrator)
        
        let args = AppleShortcutsTool.Arguments(action: "list", shortcutName: nil, input: nil)
        let result = try await tool.call(arguments: args)
        
        // Output should either be a list of shortcuts or an informational message if none are installed
        #expect(!result.isEmpty)
    }

    @Test("OSLogQueryTool retrieves process log entries")
    func testOSLogQueryTool() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = OSLogQueryTool(orchestrator: orchestrator)
        
        let args = OSLogQueryTool.Arguments(
            subsystem: nil,
            category: nil,
            level: nil,
            lastSeconds: 60,
            searchText: nil,
            limit: 10
        )
        let result = try await tool.call(arguments: args)
        #expect(!result.isEmpty)
        
        let errorLevelArgs = OSLogQueryTool.Arguments(
            subsystem: nil,
            category: nil,
            level: "error",
            lastSeconds: 60,
            searchText: nil,
            limit: 5
        )
        let errorResult = try await tool.call(arguments: errorLevelArgs)
        #expect(!errorResult.isEmpty)
    }

    @Test("WatchPathsTool start, check, and stop lifecycle")
    func testWatchPathsToolLifecycle() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = WatchPathsTool(orchestrator: orchestrator)
        
        let tempDir = NSTemporaryDirectory() + "apex_watch_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }
        
        // 1. Start watching
        let startArgs = WatchPathsTool.Arguments(action: "start", path: tempDir, watchId: nil)
        let startResult = try await tool.call(arguments: startArgs)
        #expect(startResult.contains("Started watching") || startResult.contains("watch_"))
        
        // Extract watch ID
        var watchId: String?
        if let range = startResult.range(of: #"watch_[a-zA-Z0-9]+"#, options: .regularExpression) {
            watchId = String(startResult[range])
        }
        
        // 2. Check watcher
        if let wid = watchId {
            let checkArgs = WatchPathsTool.Arguments(action: "check", path: nil, watchId: wid)
            let checkResult = try await tool.call(arguments: checkArgs)
            #expect(!checkResult.isEmpty)
            
            // 3. Stop watcher
            let stopArgs = WatchPathsTool.Arguments(action: "stop", path: nil, watchId: wid)
            let stopResult = try await tool.call(arguments: stopArgs)
            #expect(stopResult.contains("Stopped watching") || stopResult.contains("success"))
        }
    }

    @Test("NetworkDiagnosticsTool status and DNS resolution")
    func testNetworkDiagnosticsTool() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = NetworkDiagnosticsTool(orchestrator: orchestrator)
        
        // 1. Status
        let statusArgs = NetworkDiagnosticsTool.Arguments(action: "status", host: nil, port: nil, timeoutSeconds: 5)
        let statusResult = try await tool.call(arguments: statusArgs)
        #expect(statusResult.contains("Network Status") || statusResult.contains("Interface") || statusResult.contains("Status"))
        
        // 2. DNS
        let dnsArgs = NetworkDiagnosticsTool.Arguments(action: "dns", host: "localhost", port: nil, timeoutSeconds: 5)
        let dnsResult = try await tool.call(arguments: dnsArgs)
        #expect(dnsResult.contains("127.0.0.1") || dnsResult.contains("::1") || dnsResult.contains("Resolved"))
    }

    @Test("SimctlTool list action parses or executes xcrun cleanly")
    func testSimctlToolList() async throws {
        let orchestrator = AgentOrchestrator()
        let tool = SimctlTool(orchestrator: orchestrator)
        
        let listArgs = SimctlTool.Arguments(
            action: "list",
            deviceId: nil,
            appPath: nil,
            bundleId: nil,
            url: nil,
            savePath: nil
        )
        let result = try await tool.call(arguments: listArgs)
        #expect(!result.isEmpty)
    }
}
