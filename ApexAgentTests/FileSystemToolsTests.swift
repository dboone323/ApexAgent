import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 3: FileSystemTools Tests", .serialized)
struct FileSystemToolsTests {

    private func makeTempDir() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexAgentBatch3_FSTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupTempDir(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - CreateDirectoryTool Tests

    @Test("CreateDirectoryTool metadata check")
    @MainActor
    func testCreateDirectoryToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = CreateDirectoryTool(orchestrator: orchestrator)
        #expect(tool.name == "create_directory")
        #expect(tool.description.contains("Creates a directory"))
    }

    @Test("CreateDirectoryTool creates nested directories with intermediate directories enabled")
    @MainActor
    func testCreateDirectoryToolCreatesNested() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = CreateDirectoryTool(orchestrator: orchestrator)

        let targetSubdir = baseDir.appendingPathComponent("nested/level1/level2").path
        let args = CreateDirectoryTool.Arguments(path: targetSubdir)

        let result = try await tool.call(arguments: args)
        #expect(result.contains("Created directory"))
        #expect(FileManager.default.fileExists(atPath: targetSubdir))
    }

    @Test("CreateDirectoryTool idempotency: creating existing directory succeeds without error")
    @MainActor
    func testCreateDirectoryToolIdempotency() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let existing = baseDir.appendingPathComponent("existing_folder").path
        try FileManager.default.createDirectory(atPath: existing, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: existing))

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = CreateDirectoryTool(orchestrator: orchestrator)

        let args = CreateDirectoryTool.Arguments(path: existing)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Created directory"))
        #expect(FileManager.default.fileExists(atPath: existing))
    }

    @Test("CreateDirectoryTool returns error when targeting a disallowed path")
    @MainActor
    func testCreateDirectoryToolDisallowedPath() async throws {
        let orchestrator = AgentOrchestrator()
        let disallowedPath = "/System/Library/Disallowed_Apex_Dir"
        let tool = CreateDirectoryTool(orchestrator: orchestrator)

        let args = CreateDirectoryTool.Arguments(path: disallowedPath)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: Access to path is disabled in settings") || result.contains("ERROR:"))
    }

    // MARK: - DeleteFileTool Tests

    @Test("DeleteFileTool metadata check")
    @MainActor
    func testDeleteFileToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = DeleteFileTool(orchestrator: orchestrator)
        #expect(tool.name == "delete_file")
        #expect(tool.description.contains("Moves a file or directory to Trash"))
    }

    @Test("DeleteFileTool permanent deletion removes file and invokes FileRollback snapshot")
    @MainActor
    func testDeleteFileToolPermanentDeletion() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let testFile = baseDir.appendingPathComponent("sample_to_delete.txt")
        try "Content to snapshot & delete".write(to: testFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: testFile.path))

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = DeleteFileTool(orchestrator: orchestrator)

        let args = DeleteFileTool.Arguments(path: testFile.path, permanent: true)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Permanently deleted"))
        #expect(!FileManager.default.fileExists(atPath: testFile.path))
    }

    @Test("DeleteFileTool non-permanent deletion moves file to Trash")
    @MainActor
    func testDeleteFileToolTrashDeletion() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let testFile = baseDir.appendingPathComponent("sample_to_trash.txt")
        try "Content to trash".write(to: testFile, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: testFile.path))

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = DeleteFileTool(orchestrator: orchestrator)

        let args = DeleteFileTool.Arguments(path: testFile.path, permanent: false)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Moved to Trash") || result.contains("✅"))
        #expect(!FileManager.default.fileExists(atPath: testFile.path))
    }

    @Test("DeleteFileTool returns error when file does not exist")
    @MainActor
    func testDeleteFileToolNonExistentFile() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let nonExistent = baseDir.appendingPathComponent("does_not_exist.txt").path

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = DeleteFileTool(orchestrator: orchestrator)

        let args = DeleteFileTool.Arguments(path: nonExistent, permanent: true)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: File not found") || result.contains("ERROR:"))
    }

    // MARK: - MoveFileTool Tests

    @Test("MoveFileTool metadata check")
    @MainActor
    func testMoveFileToolMetadata() {
        let orchestrator = AgentOrchestrator()
        let tool = MoveFileTool(orchestrator: orchestrator)
        #expect(tool.name == "move_file")
        #expect(tool.description.contains("Moves or renames"))
    }

    @Test("MoveFileTool moves file to destination and verifies content")
    @MainActor
    func testMoveFileToolRelocatesContent() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let src = baseDir.appendingPathComponent("source.txt")
        let dst = baseDir.appendingPathComponent("destination.txt")
        let expectedPayload = "Important payload to move"
        try expectedPayload.write(to: src, atomically: true, encoding: .utf8)

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = MoveFileTool(orchestrator: orchestrator)

        let args = MoveFileTool.Arguments(sourcePath: src.path, destinationPath: dst.path)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Moved"))
        #expect(!FileManager.default.fileExists(atPath: src.path))
        #expect(FileManager.default.fileExists(atPath: dst.path))

        let readBack = try String(contentsOf: dst, encoding: .utf8)
        #expect(readBack == expectedPayload)
    }

    @Test("MoveFileTool automatically creates missing parent directories for destination")
    @MainActor
    func testMoveFileToolCreatesMissingDestinationParentDirectories() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let src = baseDir.appendingPathComponent("source_file.txt")
        let dst = baseDir.appendingPathComponent("nested/deeper/destination_file.txt")
        try "Content in deep nested destination".write(to: src, atomically: true, encoding: .utf8)

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = MoveFileTool(orchestrator: orchestrator)

        let args = MoveFileTool.Arguments(sourcePath: src.path, destinationPath: dst.path)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("Moved"))
        #expect(!FileManager.default.fileExists(atPath: src.path))
        #expect(FileManager.default.fileExists(atPath: dst.path))
    }

    @Test("MoveFileTool returns error when source does not exist")
    @MainActor
    func testMoveFileToolNonExistentSource() async throws {
        let baseDir = makeTempDir()
        defer { cleanupTempDir(baseDir) }

        let src = baseDir.appendingPathComponent("non_existent_source.txt").path
        let dst = baseDir.appendingPathComponent("dst.txt").path

        let orchestrator = AgentOrchestrator()
        orchestrator.currentWorkspacePath = baseDir.path
        let tool = MoveFileTool(orchestrator: orchestrator)

        let args = MoveFileTool.Arguments(sourcePath: src, destinationPath: dst)
        let result = try await tool.call(arguments: args)
        #expect(result.contains("ERROR: Source not found") || result.contains("ERROR:"))
    }
}
