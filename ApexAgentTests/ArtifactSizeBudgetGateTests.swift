import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Workspace Footprint & Complexity Budget Gate Tests (Batch 48)")
struct ArtifactSizeBudgetGateTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    @Test("Live repository ApexAgent/ source tree and Resources/ pass footprint and complexity budgets")
    func liveRepositoryFootprintPassesBudgetGate() {
        let report = ArtifactSizeBudgetGate.auditWorkspaceFootprint(atRepoRoot: repoRootURL)
        #expect(report.passed, "Violations: \(report.violations)")
        #expect(report.totalSwiftFiles > 100)
        #expect(report.totalSwiftLines > 40_000)
        #expect(report.totalResourceBytes > 1_000)
        #expect(report.subsystems.contains { $0.subsystem == "Models" })
        #expect(report.subsystems.contains { $0.subsystem == "Security" })
        #expect(report.toMarkdown().contains("Workspace Footprint & Complexity Budget Gate (`PASS`)"))
    }

    @Test("Workspace footprint audit resolves symlinked repository root paths without dropping resources")
    func workspaceFootprintAuditHandlesSymlinkedRoot() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("apex_audit_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let symlinkURL = tempDir.appendingPathComponent("ApexAgentSymlink")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: repoRootURL)

        let report = ArtifactSizeBudgetGate.auditWorkspaceFootprint(atRepoRoot: symlinkURL)
        #expect(report.passed, "Violations: \(report.violations)")
        #expect(report.totalResourceBytes > 1_000)
        #expect(report.subsystems.contains { $0.subsystem == "Models" })
        #expect(report.subsystems.contains { $0.subsystem == "Security" })
    }

    @Test("Flags oversized Swift files, oversized resource assets, and total footprint overflow")
    func flagsOversizedFilesAndResources() {
        let entries: [(relativePath: String, lineCount: Int, byteSize: Int, isResource: Bool)] = [
            ("ApexAgent/Models/Monolith.swift", 3100, 120_000, false),
            ("ApexAgent/Security/Compact.swift", 220, 8_500, false),
            ("ApexAgent/Resources/HugeWeights.bin", 0, 5_000_000, true),
        ]

        let report = ArtifactSizeBudgetGate.evaluate(
            entries: entries,
            maxSingleSwiftFileLines: 2500,
            maxSingleResourceBytes: 2_000_000,
            maxTotalSourceBytes: 100_000
        )

        #expect(!report.passed)
        #expect(report.violations.count == 3)
        #expect(report.violations.contains { $0.path == "ApexAgent/Models/Monolith.swift" })
        #expect(report.violations.contains { $0.path == "ApexAgent/Resources/HugeWeights.bin" })
        #expect(report.violations.contains { $0.path == "ApexAgent/" })
        #expect(report.toMarkdown().contains("Workspace Footprint & Complexity Budget Gate (`FAIL`)"))
    }
}
