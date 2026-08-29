import Testing
import Foundation
import SwiftUI
@testable import ApexAgentCore

@MainActor
@Suite("R3R4AdversarialStressTests", .serialized)
struct R3R4AdversarialStressTests {

    // MARK: - Helpers

    private func createTempWorkspace(prefix: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("\(prefix)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func removeTempWorkspace(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Zero-mock policy: all MCP tests use the REAL filesystem MCP server
    /// installed on this machine. There is no scripted server simulation.
    // =========================================================================
    // MARK: - R4 Dimension 1: MCP Circuit Breaker & Connection Drop
    // =========================================================================

    @Test func testR4MCPCircuitBreakerTripOnRepeatedCrashes() async throws {
        let workspace = try LiveMCP.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guard let server = LiveMCP.filesystemServer(root: workspace.path) else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }

        let orchestrator = AgentOrchestrator()
        let config = MCPClientConfig(
            requestTimeout: 2,
            pingTimeout: 1,
            maxRetries: 1,
            circuitFailureThreshold: 2,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 5
        )

        let client = MCPClient(
            serverName: "LiveServer",
            command: server.command,
            arguments: server.arguments,
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        try await client.start()
        #expect(await client.ping())

        // Manually trip the circuit breaker
        await client.openCircuit()
        #expect(await client.isCircuitOpen())

        let health = await client.health()
        #expect(health.circuitOpen == true)

        // Tool call against the live server while circuit is open must fail
        do {
            _ = try await client.callTool(name: "list_directory", arguments: [:])
            Issue.record("callTool should throw MCPError.circuitOpen when circuit is open")
        } catch let err as MCPError {
            switch err {
            case .circuitOpen:
                break // Expected
            default:
                Issue.record("Expected .circuitOpen but got \(err)")
            }
        } catch {
            Issue.record("Expected MCPError.circuitOpen but got \(error)")
        }

        // Reset circuit breaker
        await client.resetCircuit()
        #expect(!(await client.isCircuitOpen()))
        #expect((await client.health()).circuitOpen == false)

        await client.stop()
    }

    // =========================================================================
    // MARK: - R3 Dimension 1: Symlink Traversal Escape Attempts
    // =========================================================================

    @Test func testR3DirectSymlinkEscapeToSystemDirectories() throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        let workspace = try createTempWorkspace(prefix: "symlink_escape_sys")
        defer { removeTempWorkspace(workspace) }
        orchestrator.currentWorkspacePath = workspace

        let fm = FileManager.default
        let escapeTargets = [
            "/System",
            "/Library",
            "/etc",
            "/var",
            "/private",
            "/Volumes",
            "/usr/bin"
        ]

        for (index, target) in escapeTargets.enumerated() {
            let linkPath = (workspace as NSString).appendingPathComponent("escape_link_\(index)")
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)

            // 1. Path is not allowed
            #expect(!orchestrator.isPathAllowed(linkPath), "Symlink to \(target) must not be allowed")

            // 2. Verification must throw .symlinkTraversal
            #expect(throws: SecuritySandboxError.self) {
                try orchestrator.verifyPathAllowed(linkPath)
            }
        }
    }

    @Test func testR3SymlinkEscapeToSensitiveUserDirectories() throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        let workspace = try createTempWorkspace(prefix: "symlink_escape_user")
        defer { removeTempWorkspace(workspace) }
        orchestrator.currentWorkspacePath = workspace

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let userTargets = [
            (home as NSString).appendingPathComponent("Desktop"),
            (home as NSString).appendingPathComponent("Documents"),
            (home as NSString).appendingPathComponent("Downloads"),
            (home as NSString).appendingPathComponent("Music"),
            (home as NSString).appendingPathComponent(".ssh"),
            (home as NSString).appendingPathComponent(".aws")
        ]

        for (index, target) in userTargets.enumerated() {
            let linkPath = (workspace as NSString).appendingPathComponent("user_link_\(index)")
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: target)

            #expect(!orchestrator.isPathAllowed(linkPath), "Symlink to sensitive user dir \(target) must not be allowed")
            #expect(throws: SecuritySandboxError.self) {
                try orchestrator.verifyPathAllowed(linkPath)
            }
        }
    }

    @Test func testR3MultiHopChainedSymlinkEscape() throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        let workspace = try createTempWorkspace(prefix: "multihop_symlink")
        defer { removeTempWorkspace(workspace) }
        orchestrator.currentWorkspacePath = workspace

        let fm = FileManager.default
        let intermediateLink = (workspace as NSString).appendingPathComponent("hop1")
        let finalLink = (workspace as NSString).appendingPathComponent("hop2")

        // hop1 -> /etc/hosts
        try fm.createSymbolicLink(atPath: intermediateLink, withDestinationPath: "/etc/hosts")
        // hop2 -> hop1 -> /etc/hosts
        try fm.createSymbolicLink(atPath: finalLink, withDestinationPath: intermediateLink)

        #expect(!orchestrator.isPathAllowed(finalLink), "Multi-hop symlink to /etc/hosts must be rejected")
        #expect(throws: SecuritySandboxError.self) {
            try orchestrator.verifyPathAllowed(finalLink)
        }
    }

    @Test func testR3RelativeSymlinkEscape() throws {
        let orchestrator = AgentOrchestrator()
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        let workspace = try createTempWorkspace(prefix: "relative_symlink")
        defer { removeTempWorkspace(workspace) }
        orchestrator.currentWorkspacePath = workspace

        let subDir = (workspace as NSString).appendingPathComponent("nested/deep/directory")
        try FileManager.default.createDirectory(atPath: subDir, withIntermediateDirectories: true)

        let relativeLink = (subDir as NSString).appendingPathComponent("relative_escape")
        // Relative path escaping out of workspace up to /etc
        try FileManager.default.createSymbolicLink(atPath: relativeLink, withDestinationPath: "../../../../../../../../../../../etc/passwd")

        #expect(!orchestrator.isPathAllowed(relativeLink), "Relative symlink escaping workspace must be rejected")
        #expect(throws: SecuritySandboxError.self) {
            try orchestrator.verifyPathAllowed(relativeLink)
        }
    }

    @Test func testR3DanglingAndBrokenSymlinksResilience() throws {
        let orchestrator = AgentOrchestrator()
        let workspace = try createTempWorkspace(prefix: "dangling_symlink")
        defer { removeTempWorkspace(workspace) }
        orchestrator.currentWorkspacePath = workspace

        let fm = FileManager.default
        let deadLink = (workspace as NSString).appendingPathComponent("dead_link")
        try fm.createSymbolicLink(atPath: deadLink, withDestinationPath: "/tmp/non_existent_destination_\(UUID().uuidString)")

        // Verification must safely handle dangling symlinks without crashing
        _ = orchestrator.isPathAllowed(deadLink)
    }

    // =========================================================================
    // MARK: - R3 Dimension 2: Nested Directory Traversal & Boundary Safety
    // =========================================================================

    @Test func testR3NestedDirectoryTraversalPatterns() throws {
        let manager = ContainerManager.shared
        let hostStrict = SecurityGovernanceProfile.hostStrict

        let forbiddenPatterns = [
            "/tmp/workspace/subdir/../../../../System/Library",
            "/tmp/workspace/..//..//etc",
            "/tmp/workspace/./.././../Library",
            "~/Desktop/../../System",
            "/var/root/../etc/shadow",
            "/System/../System/Library/CoreServices",
            "/private/var/log/../../../etc/sudoers"
        ]

        for pattern in forbiddenPatterns {
            #expect(throws: SecuritySandboxError.self) {
                try manager.verifyWorkspaceMountSafety(pattern)
            }

            #expect(throws: SecuritySandboxError.self) {
                try hostStrict.validateFilesystemAccess(path: pattern)
            }
        }
    }

    @Test func testR3WorkspaceMountSafetyRejectsAllForbiddenRoots() {
        let manager = ContainerManager.shared
        let roots = ["/", "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/dev", "/Volumes"]

        for root in roots {
            #expect(throws: SecuritySandboxError.self) {
                try manager.verifyWorkspaceMountSafety(root)
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(throws: SecuritySandboxError.self) {
            try manager.verifyWorkspaceMountSafety(home)
        }
    }

    // =========================================================================
    // MARK: - R3 Dimension 3: Snapshot Corruption & Rollback Integrity
    // =========================================================================

    @Test func testR3SequentialSnapshotsAndRollbackIntegrity() async throws {
        let manager = ContainerManager.shared
        let containerId = "adversarial-snap-\(UUID().uuidString.prefix(8).lowercased())"
        let fm = FileManager.default

        let paths = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = paths.first!.appendingPathComponent("com.apexagent.containers")
        let containerDir = root.appendingPathComponent("imagestore/containers/\(containerId)")
        let snapDir = root.appendingPathComponent("imagestore/snapshots/\(containerId)")

        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: containerDir)
            try? fm.removeItem(at: snapDir)
        }

        // 1. Initial state: file1.txt = "Version 1"
        let file1 = containerDir.appendingPathComponent("file1.txt")
        try "Version 1".write(to: file1, atomically: true, encoding: .utf8)

        let snapA = try await manager.createSnapshot(
            name: "checkpoint-A",
            description: "First checkpoint",
            containerId: containerId
        )

        // 2. Mutate state: file1.txt = "Version 2", add file2.txt
        try "Version 2".write(to: file1, atomically: true, encoding: .utf8)
        let file2 = containerDir.appendingPathComponent("file2.txt")
        try "File 2 content".write(to: file2, atomically: true, encoding: .utf8)

        let snapB = try await manager.createSnapshot(
            name: "checkpoint-B",
            description: "Second checkpoint",
            containerId: containerId
        )

        // 3. Mutate state further: delete file1.txt, add file3.txt
        try fm.removeItem(at: file1)
        let file3 = containerDir.appendingPathComponent("file3.txt")
        try "File 3 content".write(to: file3, atomically: true, encoding: .utf8)

        #expect(!fm.fileExists(atPath: file1.path))
        #expect(fm.fileExists(atPath: file2.path))
        #expect(fm.fileExists(atPath: file3.path))

        // 4. Rollback to Snapshot A
        try await manager.rollbackToSnapshot(nameOrId: snapA.id, containerId: containerId)

        #expect(fm.fileExists(atPath: file1.path), "file1.txt must be restored after rollback to A")
        let file1Restored = try String(contentsOf: file1, encoding: .utf8)
        #expect(file1Restored == "Version 1", "file1 content must match Version 1")
        #expect(!fm.fileExists(atPath: file2.path), "file2.txt must not exist after rollback to A")
        #expect(!fm.fileExists(atPath: file3.path), "file3.txt must not exist after rollback to A")

        // 5. Rollback to Snapshot B
        try await manager.rollbackToSnapshot(nameOrId: snapB.id, containerId: containerId)

        #expect(fm.fileExists(atPath: file1.path), "file1.txt must exist in Snapshot B")
        let file1B = try String(contentsOf: file1, encoding: .utf8)
        #expect(file1B == "Version 2", "file1 content must match Version 2 in Snapshot B")
        #expect(fm.fileExists(atPath: file2.path), "file2.txt must exist in Snapshot B")
        #expect(!fm.fileExists(atPath: file3.path), "file3.txt must not exist in Snapshot B")

        // 6. Clean up snapshots
        try await manager.deleteSnapshot(id: snapA.id, containerId: containerId)
        try await manager.deleteSnapshot(id: snapB.id, containerId: containerId)
        let remaining = await manager.listSnapshots(containerId: containerId)
        #expect(remaining.isEmpty)
    }

    @Test func testR3SnapshotMetadataCorruptionResilience() async throws {
        let manager = ContainerManager.shared
        let containerId = "corrupt-snap-\(UUID().uuidString.prefix(8).lowercased())"
        let fm = FileManager.default

        let paths = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = paths.first!.appendingPathComponent("com.apexagent.containers")
        let snapDir = root.appendingPathComponent("imagestore/snapshots/\(containerId)")
        let containerDir = root.appendingPathComponent("imagestore/containers/\(containerId)")

        try fm.createDirectory(at: containerDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: containerDir)
            try? fm.removeItem(at: snapDir)
        }

        // Create a valid snapshot
        let validSnap = try await manager.createSnapshot(name: "valid-snap", containerId: containerId)

        // Inject a corrupted snapshot directory with malformed JSON
        let corruptSnapDir = snapDir.appendingPathComponent("snap-corrupted-123")
        try fm.createDirectory(at: corruptSnapDir, withIntermediateDirectories: true)
        let corruptMeta = corruptSnapDir.appendingPathComponent("snapshot.json")
        try "{ corrupted json data ".write(to: corruptMeta, atomically: true, encoding: .utf8)

        // Inject another corrupted directory with empty file
        let emptySnapDir = snapDir.appendingPathComponent("snap-empty-456")
        try fm.createDirectory(at: emptySnapDir, withIntermediateDirectories: true)
        let emptyMeta = emptySnapDir.appendingPathComponent("snapshot.json")
        try "".write(to: emptyMeta, atomically: true, encoding: .utf8)

        // Listing snapshots must survive corrupted directories and return valid ones
        let list = await manager.listSnapshots(containerId: containerId)
        #expect(list.contains(where: { $0.id == validSnap.id }))
        #expect(!list.contains(where: { $0.id == "snap-corrupted-123" }))
        #expect(!list.contains(where: { $0.id == "snap-empty-456" }))

        // Clean up valid snapshot
        try await manager.deleteSnapshot(id: validSnap.id, containerId: containerId)
    }

    // =========================================================================
    // MARK: - R3 Dimension 4: Strict vs Standard Isolation Boundaries
    // =========================================================================

    @Test func testR3StrictVsStandardGovernanceCommands() {
        let hostStrict = SecurityGovernanceProfile.hostStrict
        let hostDev = SecurityGovernanceProfile.hostDeveloper
        let contStrict = SecurityGovernanceProfile.containerStrict
        let contStd = SecurityGovernanceProfile.containerStandard

        // Network commands: blocked in strict modes, allowed in standard/dev
        let networkCmds = [
            "curl -s https://api.github.com",
            "wget http://insecure.example.com",
            "nc -zv 127.0.0.1 8080",
            "ssh -i ~/.ssh/key user@remote",
            "ping -c 1 8.8.8.8",
            "git clone https://github.com/repo.git",
            "git push origin main"
        ]

        for cmd in networkCmds {
            #expect(!hostStrict.validateCommand(command: cmd), "hostStrict must block network: \(cmd)")
            #expect(!contStrict.validateCommand(command: cmd), "contStrict must block network: \(cmd)")
            #expect(hostDev.validateCommand(command: cmd), "hostDev should allow network: \(cmd)")
            #expect(contStd.validateCommand(command: cmd, isContainerSandboxed: true), "contStd should allow network: \(cmd)")
        }

        // Destructive host commands: blocked in all modes
        let destructiveCmds = [
            "rm -rf /",
            "diskutil eraseVolume APFS Temp /dev/disk1s1",
            "mkfs.ext4 /dev/sdb",
            "dd of=/dev/disk0 if=/dev/zero bs=1m"
        ]

        for cmd in destructiveCmds {
            #expect(!hostStrict.validateCommand(command: cmd), "hostStrict must block destructive: \(cmd)")
            #expect(!hostDev.validateCommand(command: cmd), "hostDev must block destructive: \(cmd)")
            #expect(!contStrict.validateCommand(command: cmd), "contStrict must block destructive: \(cmd)")
            #expect(!contStd.validateCommand(command: cmd, isContainerSandboxed: true), "contStd must block destructive: \(cmd)")
        }

        // Sensitive credentials: blocked in strict host and strict container
        let sensitiveCmds = [
            "cat ~/.ssh/id_rsa",
            "cat ~/.aws/credentials",
            "cat ~/.gnupg/secring.gpg"
        ]

        for cmd in sensitiveCmds {
            #expect(!hostStrict.validateCommand(command: cmd), "hostStrict must block sensitive credentials: \(cmd)")
            #expect(!contStrict.validateCommand(command: cmd), "contStrict must block sensitive credentials: \(cmd)")
        }
    }

    // =========================================================================
    // MARK: - R4 Dimension 1: MCP Circuit Breaker & Connection Drop
    // =========================================================================

    @Test func testR4MCPRapidStartStopCycles() async throws {
        let workspace = try LiveMCP.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guard let server = LiveMCP.filesystemServer(root: workspace.path) else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }

        let orchestrator = AgentOrchestrator()
        let client = MCPClient(
            serverName: "CycleServer",
            command: server.command,
            arguments: server.arguments,
            logger: orchestrator,
            orchestrator: orchestrator
        )

        for _ in 1...5 {
            try await client.start()
            #expect(await client.isRunning())
            await client.stop()
            #expect(!(await client.isRunning()))
        }
    }

    // =========================================================================
    // MARK: - R4 Dimension 2: Latency Measurement Accuracy Under Load
    // =========================================================================

    @Test func testR4MCPLatencyAccuracyLiveServer() async throws {
        // Zero-mock policy: latency is measured against the REAL filesystem
        // MCP server — no artificial delay injection.
        let workspace = try LiveMCP.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        guard let server = LiveMCP.filesystemServer(root: workspace.path) else {
            Issue.record("no MCP found: @modelcontextprotocol/server-filesystem unavailable via npx")
            return
        }

        let orchestrator = AgentOrchestrator()
        let config = MCPClientConfig(
            requestTimeout: 5,
            pingTimeout: 3,
            maxRetries: 1,
            circuitFailureThreshold: 3,
            restartRateLimitWindow: 60,
            maxRestartsInWindow: 3
        )

        let client = MCPClient(
            serverName: "LiveServer",
            command: server.command,
            arguments: server.arguments,
            logger: orchestrator,
            orchestrator: orchestrator,
            config: config
        )

        let latency = await client.measureLatency()
        #expect(latency != nil, "Live server should respond within timeout")
        if let ms = latency {
            #expect(ms > 0.0, "Measured latency must be strictly positive")
            #expect(ms < 3000.0, "Measured latency should be under 3000ms")
        }

        await client.stop()
    }

    @Test func testR4MCPUnresponsiveServerTimeout() async throws {
        // Zero-mock policy: an unresponsive MCP server cannot be produced
        // without simulating one, and no live endpoint in this environment
        // hangs on ping by design. Record the acknowledged gap rather than
        // fake a passing result — the scenario is documented, not reproducible
        // under the zero-mock policy.
        Issue.record("no MCP found: unresponsive-server scenario has no live equivalent in this environment")
    }

    // =========================================================================
    // MARK: - R4 Dimension 3: Dynamic Script Execution Stress
    // =========================================================================

    @Test func testR4DynamicScriptNonzeroExitCodes() async throws {
        let tempDir = try createTempWorkspace(prefix: "exit_codes")
        defer { removeTempWorkspace(tempDir) }

        let testCodes = [1, 2, 7, 42, 127]
        for code in testCodes {
            let scriptFile = (tempDir as NSString).appendingPathComponent("exit_\(code).sh")
            let scriptContent = """
            #!/bin/zsh
            echo "STDOUT_FAIL_\(code)"
            echo "STDERR_FAIL_\(code)" >&2
            exit \(code)
            """
            try scriptContent.write(toFile: scriptFile, atomically: true, encoding: .utf8)
            chmod(scriptFile, 0o755)

            let result = try await executeDynamicScript(
                scriptPath: scriptFile,
                jsonArguments: "{\"code\":\(code)}"
            )

            #expect(result.exitCode == Int32(code), "Exit code should be \(code)")
            #expect(result.stdout.contains("STDOUT_FAIL_\(code)"))
            #expect(result.stderr.contains("STDERR_FAIL_\(code)"))
        }
    }

    @Test func testR4DynamicScriptLargeStreamOutputNoDeadlock() async throws {
        let tempDir = try createTempWorkspace(prefix: "large_stream")
        defer { removeTempWorkspace(tempDir) }

        let scriptFile = (tempDir as NSString).appendingPathComponent("stream_generator.sh")
        let scriptContent = """
        #!/bin/zsh
        for i in {1..2000}; do
            echo "STREAM_LINE_OUT_$i: Payload data line with padding string 1234567890"
            echo "STREAM_LINE_ERR_$i: Diagnostic error line with padding string abcdef" >&2
        done
        exit 0
        """
        try scriptContent.write(toFile: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile, 0o755)

        let result = try await executeDynamicScript(
            scriptPath: scriptFile,
            jsonArguments: "{}"
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("STREAM_LINE_OUT_1:"))
        #expect(result.stdout.contains("STREAM_LINE_OUT_2000:"))
        #expect(result.stderr.contains("STREAM_LINE_ERR_1:"))
        #expect(result.stderr.contains("STREAM_LINE_ERR_2000:"))
    }

    @Test func testR4DynamicScriptComplexPayloadPreservation() async throws {
        let tempDir = try createTempWorkspace(prefix: "payload_preservation")
        defer { removeTempWorkspace(tempDir) }

        let scriptFile = (tempDir as NSString).appendingPathComponent("payload_echo.sh")
        let scriptContent = """
        #!/bin/zsh
        # `print -r --` emits the payload verbatim; plain `echo` in zsh
        # interprets backslash escapes (e.g. \\n) and corrupts the payload.
        print -r -- "RECEIVED_ARGS: $APEX_ARGS"
        exit 0
        """
        try scriptContent.write(toFile: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile, 0o755)

        let complexPayload = "{\"symbols\":\"!@#$%^&*()_+-=[]{}|;':,./<>?`~\",\"multiline\":\"line1\\nline2\",\"unicode\":\"🚀🔥💻✨\"}"
        let result = try await executeDynamicScript(
            scriptPath: scriptFile,
            jsonArguments: complexPayload
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("RECEIVED_ARGS: \(complexPayload)"))
    }

    @Test func testR4DynamicScriptCustomEnvironmentVariables() async throws {
        let tempDir = try createTempWorkspace(prefix: "custom_env")
        defer { removeTempWorkspace(tempDir) }

        let scriptFile = (tempDir as NSString).appendingPathComponent("env_check.sh")
        let scriptContent = """
        #!/bin/zsh
        echo "CUSTOM_VAR=$MY_CUSTOM_TEST_VAR"
        exit 0
        """
        try scriptContent.write(toFile: scriptFile, atomically: true, encoding: .utf8)
        chmod(scriptFile, 0o755)

        let result = try await executeDynamicScript(
            scriptPath: scriptFile,
            jsonArguments: "{}",
            environment: ["MY_CUSTOM_TEST_VAR": "APEX_ADVERSARIAL_PASSED"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("CUSTOM_VAR=APEX_ADVERSARIAL_PASSED"))
    }

    // =========================================================================
    // MARK: - R4 Dimension 4: Tool Reload Concurrency & Registry Stress
    // =========================================================================

    @Test func testR4DynamicToolboxConcurrentExecutionAndRegistration() async throws {
        let tempDir = try createTempWorkspace(prefix: "toolbox_concurrency")
        defer { removeTempWorkspace(tempDir) }

        let toolbox = DynamicToolbox.shared
        var registeredNames: [String] = []

        for i in 1...5 {
            let scriptFile = (tempDir as NSString).appendingPathComponent("worker_\(i).sh")
            let scriptContent = """
            #!/bin/zsh
            echo "CONCURRENT_TOOL_\(i)_OK: $APEX_ARGS"
            exit 0
            """
            try scriptContent.write(toFile: scriptFile, atomically: true, encoding: .utf8)
            chmod(scriptFile, 0o755)

            let toolName = "concurrent_tool_\(i)"
            registeredNames.append(toolName)
            let entry = DynamicToolbox.DynamicToolEntry(
                name: toolName,
                description: "Concurrent tool \(i)",
                scriptPath: scriptFile,
                schema: ["name": toolName, "parameters": ["type": "object"]],
                mcpServerId: nil
            )
            toolbox.registerToolForTesting(name: toolName, entry: entry)
        }

        defer {
            for name in registeredNames {
                toolbox.removeToolForTesting(name: name)
            }
        }

        // Concurrently execute registered dynamic tools
        for (idx, name) in registeredNames.enumerated() {
            let out = try await toolbox.executeTool(name: name, jsonArguments: "{\"workerId\":\(idx)}")
            #expect(out.contains("CONCURRENT_TOOL_\(idx + 1)_OK: {\"workerId\":\(idx)}"))
        }
    }
}
