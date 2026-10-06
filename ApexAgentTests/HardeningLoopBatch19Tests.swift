import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch19Tests")
struct HardeningLoopBatch19Tests {
    @Test func testDiffStatsBadge() {
        #expect(DiffStats(additions: 0, deletions: 0, unchanged: 5).badge.contains("No Changes"))
        #expect(DiffStats(additions: 3, deletions: 0, unchanged: 1).badge.contains("Additions"))
        #expect(DiffStats(additions: 0, deletions: 2, unchanged: 1).badge.contains("Deletions"))
        #expect(DiffStats(additions: 2, deletions: 2, unchanged: 1).badge.contains("Mixed"))
        let row = DiffStats(additions: 2, deletions: 1, unchanged: 0).formatAsMarkdownRow(filePath: "a.swift")
        #expect(row.contains("a.swift"))
    }

    @Test func testDiffLineFormat() {
        let long = String(repeating: "x", count: 300)
        let line = DiffLine(kind: .added, text: long, lineNumber: nil)
        #expect(line.formatTruncated().count <= 162)
        #expect(line.formatTruncated().hasPrefix("+"))
        let del = DiffLine(kind: .deleted, text: "gone", lineNumber: 3)
        #expect(del.formatTruncated().hasPrefix("-"))
    }

    @Test func testLaunchAgentValidation() {
        let ok = LaunchAgentConfig(label: "com.apexagent.daemon", programPath: "/usr/local/bin/apex", arguments: ["--daemon"])
        #expect(ok.isValid)
        #expect(ok.formatAsMarkdown().contains("apexagent"))
        let bad = LaunchAgentConfig(label: "notadns", programPath: "", arguments: [])
        #expect(!bad.isValid)
        #expect(bad.validationError() != nil)
    }

    @Test func testUnifiedDiff() {
        let diff = DiffHelper.computeDiff(oldText: "a\nb", newText: "a\nc")
        let stats = DiffHelper.computeStats(diff: diff)
        #expect(stats.additions == 1 && stats.deletions == 1)
        let unified = DiffHelper.formatUnifiedDiff(oldText: "a\nb", newText: "a\nc", filePath: "f.txt")
        #expect(unified.contains("f.txt"))
    }
}
