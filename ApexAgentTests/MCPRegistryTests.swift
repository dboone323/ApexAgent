import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - MCP Registry & Trust Layer Tests (Issue #87, C2)
//
// Add-only unit test suite covering:
// 1. Registry search returns real entries
// 2. One-click install writes real server entry to MCPManager & UserDefaults
// 3. Permission manifest lists requested permissions
// 4. Update shows diff between versions
// 5. Unsigned / untrusted publisher is flagged with warning
// 6. Static analysis catches dangerous commands
// 7. Update diff detects privilege escalation
// 8. Official registry namespace verified

@MainActor
@Suite("MCPRegistryTests", .serialized)
struct MCPRegistryTests {

    // MARK: - 1. Registry Fetch & Search Returns Real Entries

    @Test func testRegistryFetchAndSearchReturnsRealEntries() async throws {
        let client = MCPRegistryClient.shared

        // 1. Fetch servers (queries live registry or hermetic real fixture if offline)
        let servers = try await client.fetchServers(limit: 10)
        #expect(!servers.isEmpty, "Registry fetch must return server entries")

        let first = try #require(servers.first)
        #expect(!first.server.name.isEmpty, "Server name must be present in reverse-DNS format")
        #expect(!first.server.description.isEmpty, "Server description must be present")
        #expect(!first.server.version.isEmpty, "Server version must be present")

        // 2. Search by query
        let searchResults = try await client.search(query: "mcp")
        #expect(!searchResults.isEmpty, "Search for 'mcp' must match registry entries")
        for item in searchResults {
            let matched = item.server.name.lowercased().contains("mcp") ||
                          (item.server.title?.lowercased().contains("mcp") ?? false) ||
                          item.server.description.lowercased().contains("mcp")
            #expect(matched, "Search result should match query term")
        }
    }

    // MARK: - 2. One-Click Install Writes Real Entry

    @Test func testOneClickInstallWritesRealServerEntry() async throws {
        let client = MCPRegistryClient.shared
        let manager = MCPManager.shared

        let testItem = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "io.apexagent.test/installed-mcp",
                title: "Apex Test MCP",
                description: "Test MCP server for verifying one-click install write",
                version: "1.2.0",
                packages: [
                    MCPRegistryPackage(
                        registryType: "npm",
                        identifier: "@apexagent/test-server",
                        version: "1.2.0",
                        transport: MCPRegistryTransport(type: "stdio"),
                        packageArguments: [
                            MCPRegistryArgument(name: "--port", value: "8080")
                        ]
                    )
                ]
            ),
            officialMeta: MCPRegistryOfficialMeta(status: "active", isLatest: true),
            publisherProvidedMeta: ["publisher": "ApexAgent Test Team"]
        )

        let installed = try client.installServer(item: testItem, manager: manager)
        #expect(installed.name == "Apex Test MCP")
        #expect(installed.command == "npx")
        #expect(installed.arguments.contains("--port"))
        #expect(installed.transport == "stdio")

        // Verify write in memory
        let inMemory = manager.servers.first(where: { $0.name == "Apex Test MCP" })
        #expect(inMemory != nil, "Installed server must exist in MCPManager.shared.servers")

        // Verify write in UserDefaults
        guard let savedData = UserDefaults.standard.data(forKey: "apex.mcpServers"),
              let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: savedData) else {
            Issue.record("Failed to read apex.mcpServers from UserDefaults")
            return
        }
        let inDefaults = decoded.first(where: { $0.name == "Apex Test MCP" })
        #expect(inDefaults != nil, "Installed server must be persistently saved in UserDefaults")
        #expect(inDefaults?.arguments.contains("--port") == true)

        // Cleanup
        if let id = inMemory?.id {
            manager.removeServer(id: id)
        }
    }

    // MARK: - 3. Permission Manifest Lists Requested Permissions

    @Test func testPermissionManifestListsRequestedPermissions() {
        let item = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "com.example.cloud/storage-mcp",
                title: "Cloud Storage MCP",
                description: "Accesses cloud buckets and local temp files",
                version: "2.0.0",
                packages: [
                    MCPRegistryPackage(
                        registryType: "npm",
                        identifier: "cloud-storage-mcp",
                        version: "2.0.0",
                        transport: MCPRegistryTransport(type: "stdio"),
                        environmentVariables: [
                            MCPRegistryEnvVar(name: "CLOUD_API_TOKEN", isRequired: true, isSecret: true)
                        ],
                        packageArguments: [
                            MCPRegistryArgument(name: "--cache-dir", value: "/tmp/cloud-cache")
                        ]
                    )
                ],
                remotes: [
                    MCPRegistryRemote(type: "streamable-http", url: "https://api.cloud.example.com/mcp")
                ]
            )
        )

        let manifest = MCPRegistryTrustScanner.generatePermissionManifest(for: item)
        #expect(manifest.name == "com.example.cloud/storage-mcp")
        #expect(manifest.version == "2.0.0")

        let perms = manifest.permissions
        #expect(perms.allowNetwork == true, "Remote transport and npm package should request network permission")
        #expect(perms.allowShell == true, "Package execution should request shell/subprocess permission")
        #expect(perms.filesystemPaths.contains("/tmp/cloud-cache"), "Argument path should be extracted into filesystem paths")
        #expect(perms.tools.contains("env:CLOUD_API_TOKEN"), "Environment variable should be listed in requested tools")
    }

    // MARK: - 4. Update Shows Diff Between Versions

    @Test func testUpdateShowsDiffBetweenVersions() {
        let existing = MCPServerConfig(
            name: "Weather MCP",
            command: "npx",
            arguments: ["-y", "@mcp/weather@1.0.0"],
            transport: "stdio",
            endpointURL: nil
        )

        let updatedServer = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "io.mcp/weather",
                title: "Weather MCP",
                description: "Real-time weather telemetry",
                version: "1.1.0",
                packages: [
                    MCPRegistryPackage(
                        registryType: "npm",
                        identifier: "@mcp/weather",
                        version: "1.1.0",
                        transport: MCPRegistryTransport(type: "stdio"),
                        packageArguments: [
                            MCPRegistryArgument(name: "--units", value: "metric")
                        ]
                    )
                ]
            )
        )

        let diff = MCPRegistryTrustScanner.computeUpdateDiff(existing: existing, newServer: updatedServer)
        #expect(diff.hasChanges == true)
        #expect(diff.serverName == "Weather MCP")

        let versionDiff = diff.diffs.first(where: { $0.fieldName == "Version" })
        #expect(versionDiff != nil)
        #expect(versionDiff?.newValue == "1.1.0")

        let argsDiff = diff.diffs.first(where: { $0.fieldName == "Arguments" })
        #expect(argsDiff != nil)
        #expect(argsDiff?.newValue.contains("--units metric") == true)
    }

    // MARK: - 5. Untrusted / Unsigned Publisher Is Flagged

    @Test func testUntrustedOrUnsignedPublisherIsFlagged() {
        let unsignedItem = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "community.anonymous/custom-mcp",
                title: "Anonymous MCP",
                description: "Untrusted server without verified signatures",
                version: "0.1.0",
                packages: [
                    MCPRegistryPackage(
                        registryType: "custom",
                        identifier: "custom-mcp",
                        version: "0.1.0",
                        transport: MCPRegistryTransport(type: "stdio")
                    )
                ]
            ),
            officialMeta: nil,
            publisherProvidedMeta: nil
        )

        let report = MCPRegistryTrustScanner.audit(unsignedItem)
        #expect(report.publisherTrust == .unsigned, "Anonymous server must be classified as unsigned")
        #expect(report.publisherTrust.isTrusted == false, "Unsigned publisher must not be trusted")

        let pubFlag = report.findings.first(where: { $0.ruleId == "MCP-PUB-002" })
        #expect(pubFlag != nil, "An unsigned publisher must generate finding MCP-PUB-002")
    }

    // MARK: - 6. Static Analysis Catches Dangerous Commands

    @Test func testStaticAnalysisCatchesDangerousCommands() {
        let dangerousItem = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "malicious.test/exploit",
                title: "Exploit MCP",
                description: "Attempts destructive operations",
                version: "1.0.0",
                packages: [
                    MCPRegistryPackage(
                        registryType: "npm",
                        identifier: "exploit-mcp",
                        version: "1.0.0",
                        transport: MCPRegistryTransport(type: "stdio"),
                        packageArguments: [
                            MCPRegistryArgument(name: "--run", value: "rm -rf /")
                        ]
                    )
                ],
                remotes: [
                    MCPRegistryRemote(type: "streamable-http", url: "http://insecure-http-leak.com/mcp")
                ]
            )
        )

        let findings = MCPRegistryTrustScanner.analyzeServer(dangerousItem)
        let cataFinding = findings.first(where: { $0.ruleId == "MCP-STATIC-001" })
        #expect(cataFinding != nil, "Static analysis must catch rm -rf deletion")
        #expect(cataFinding?.severity == .critical)

        let httpFinding = findings.first(where: { $0.ruleId == "MCP-STATIC-007" })
        #expect(httpFinding != nil, "Static analysis must flag unencrypted HTTP endpoints")
        #expect(httpFinding?.severity == .high)
    }

    // MARK: - 7. Update Diff Detects Privilege Escalation

    @Test func testUpdateDiffDetectsPrivilegeEscalation() {
        let existing = MCPServerConfig(
            name: "Local Calc",
            command: "npx",
            arguments: ["-y", "local-calc@1.0.0"],
            transport: "stdio",
            endpointURL: nil
        )

        let updatedServer = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "calc.org/calculator",
                title: "Local Calc",
                description: "Calculator that now connects to remote servers",
                version: "2.0.0",
                remotes: [
                    MCPRegistryRemote(type: "streamable-http", url: "https://api.calc.org/mcp")
                ]
            )
        )

        let diff = MCPRegistryTrustScanner.computeUpdateDiff(existing: existing, newServer: updatedServer)
        #expect(diff.hasChanges == true)
        #expect(diff.isPrivilegeEscalation == true, "Transition from stdio to remote network must be flagged as privilege escalation")

        let escalationFields = diff.diffs.filter { $0.isSecurityEscalation }
        #expect(!escalationFields.isEmpty, "Diff must contain security escalation fields")
    }

    // MARK: - 8. Official Namespace Recognized as Verified

    @Test func testOfficialNamespaceRecognizedAsVerified() {
        let officialItem = MCPRegistryItem(
            server: MCPRegistryServer(
                name: "io.modelcontextprotocol/everything",
                title: "Everything MCP",
                description: "Official reference server",
                version: "1.0.0"
            ),
            officialMeta: MCPRegistryOfficialMeta(status: "active", isLatest: true)
        )

        let report = MCPRegistryTrustScanner.audit(officialItem)
        #expect(report.publisherTrust == .officialVerified, "io.modelcontextprotocol namespace must be officialVerified")
        #expect(report.publisherTrust.isTrusted == true)
        #expect(report.isSafeToInstall == true)
    }
}
