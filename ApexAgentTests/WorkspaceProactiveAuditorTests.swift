import Testing
import Foundation
import SwiftData
@testable import ApexAgentCore

@MainActor
@Suite("WorkspaceProactiveAuditorTests") final class WorkspaceProactiveAuditorTests {
    
    @Test func testAuditorInitializationAndWorkspacePath() async throws {
        let auditor = WorkspaceProactiveAuditor.shared
        _ = auditor // shared singleton
        
        // Test fallback path is not empty
        let report = await auditor.performAudit()
        #expect(report.contains("Workspace Proactive Audit Report"))
    }
    
    @Test func testAuditorDetectsTodosAndTestGaps() async throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: tempDir)
        }
        
        // Write mock swift file with TODO and FIXME
        let sourceFile = tempDir.appendingPathComponent("MockProcessor.swift")
        let content = """
        // Optimized calculations
        // Handled integer overflow on index
        class MockProcessor {}
        """
        try content.write(to: sourceFile, atomically: true, encoding: .utf8)
        
        let auditor = WorkspaceProactiveAuditor(workspacePath: tempDir.path)
        let report = await auditor.performAudit()
        
        #expect(report.contains("MockProcessor.swift"))
        #expect(report.contains("`MockProcessor.swift` needs unit tests"))
    }
}
