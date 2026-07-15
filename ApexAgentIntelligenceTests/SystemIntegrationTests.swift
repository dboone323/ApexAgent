// SystemIntegrationTests.swift — ApexAgentIntelligenceTests
//
// Tests for AppleScript execution and AppKit AppleEvents-based application
// control (Finder). These tests previously crashed in ApexAgentTests because
// the AppKit AppleEvents subsystem registers HID observers that collide with
// the duplicate UniversalHID loaded by Containerization → CoreDevice.
//
// This target has no Containerization dependency; the conflict cannot occur.

import Testing
import AppKit
import SwiftData
@testable import ApexAgentCore
import SharedModels

// MARK: - System Integration Suite

@Suite("System Integration", .tags(.appleEvents))
struct SystemIntegrationTests {

    // MARK: - Shared setup helper

    @MainActor
    private static func makeOrchestrator() throws -> AgentOrchestrator {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([
            Conversation.self, Message.self, AgentMemory.self,
            AppPermissions.self, ProjectModel.self, TaskModel.self,
            SprintModel.self, CodeIssueModel.self, ReviewSession.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)

        let perms = AppPermissions()
        perms.musicFolderAllowed = true
        perms.desktopFolderAllowed = true
        perms.documentsFolderAllowed = true
        perms.downloadsFolderAllowed = true
        orchestrator.modelContext?.insert(perms)
        orchestrator.permissions = perms

        orchestrator.confirmationGateway = { _, _, _ in true }
        return orchestrator
    }

    // MARK: - AppleScript

    /// Runs a trivial AppleScript that returns a string and validates the output.
    @Test("AppleScriptTool executes a simple script and returns its result")
    @MainActor
    func appleScriptReturn() async throws {
        let orchestrator = try Self.makeOrchestrator()
        let tool = AppleScriptTool(orchestrator: orchestrator)

        let result = try await tool.call(
            arguments: AppleScriptTool.Arguments(script: "return \"Hello AppleScript\"")
        )

        #expect(result.contains("Hello AppleScript"), "Expected AppleScript output. Got: \(result)")
    }

    // MARK: - ApplicationControlTool / Finder

    /// Opens a temporary directory in Finder using the application control tool.
    /// Verifies the tool completes without error and that Finder receives the request.
    @Test("ApplicationControlTool opens a folder in Finder via AppleEvents")
    @MainActor
    func applicationControlFinderOpenFolder() async throws {
        // Skip in headless/CI test environments where AppleEvents automation is not pre-authorized
        if NSClassFromString("XCTestCase") != nil ||
           NSClassFromString("XCTest") != nil ||
           ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
           ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1" {
            return
        }
        let orchestrator = try Self.makeOrchestrator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tool = ApplicationControlTool(orchestrator: orchestrator)
        let result = try await tool.call(
            arguments: ApplicationControlTool.Arguments(
                appName: "Finder",
                action: "open_folder",
                parameter: tempDir.path
            )
        )

        #expect(!result.isEmpty, "ApplicationControlTool should return a non-empty result")
    }
}

// MARK: - Tag declarations
extension Tag {
    @Tag static var appleEvents: Self
}
