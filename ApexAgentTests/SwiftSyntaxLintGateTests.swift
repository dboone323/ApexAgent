import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 32 — Diff-Scoped Swift Syntax, Format & Lint Gate Tests", .serialized)
struct SwiftSyntaxLintGateTests {

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Detects git merge conflict markers, duplicate imports, and tab indentation")
    func detectsConflictMarkersDuplicateImportsAndTabIndentation() {
        let markerStart = String(repeating: "<", count: 7) + " HEAD"
        let markerMid = String(repeating: "=", count: 7)
        let markerEnd = String(repeating: ">", count: 7) + " feature"
        let tabIndented = "\tlet x = 1"

        let source = """
        import Foundation
        import Foundation
        struct Sample {
        \(markerStart)
        \(tabIndented)
        \(markerMid)
            let x = 2
        \(markerEnd)
        }
        """

        let issues = SwiftSyntaxLintGate.analyzeSwiftSource(source, filePath: "ApexAgent/Broken.swift")
        let kinds = issues.map(\.kind)
        #expect(kinds.contains(.duplicateImport))
        #expect(kinds.contains(.tabIndentation))
        #expect(issues.filter { $0.kind == .mergeConflictMarker }.count == 3)
    }

    @Test("Balanced delimiter analyzer catches unclosed or mismatched braces while ignoring strings and comments")
    func balancedDelimiterAnalyzerRespectsStringsAndComments() {
        let validComplexSource = """
        import Foundation
        // Comment with unmatched { ( [
        /* Block comment with } ] ) */
        struct Valid {
            let text = "unbalanced { in string \\"still in string {\\""
            let multi = \"\"\"
            multiline with { [ (
            \"\"\"
            func compute() -> [Int] {
                return [1, 2, 3]
            }
        }
        """
        let cleanIssues = SwiftSyntaxLintGate.analyzeSwiftSource(validComplexSource, filePath: "ApexAgent/Valid.swift")
        #expect(cleanIssues.isEmpty)

        let unclosedSource = """
        struct Unclosed {
            func test() {
                let a = [1, 2, 3]
        }
        """
        let unclosedIssues = SwiftSyntaxLintGate.analyzeSwiftSource(unclosedSource, filePath: "ApexAgent/Unclosed.swift")
        #expect(unclosedIssues.count == 1)
        #expect(unclosedIssues.first?.kind == .unbalancedDelimiter)

        let mismatchedSource = """
        struct Mismatched {
            let arr = [1, 2, 3)
        }
        """
        let mismatchedIssues = SwiftSyntaxLintGate.analyzeSwiftSource(mismatchedSource, filePath: "ApexAgent/Mismatched.swift")
        #expect(mismatchedIssues.count == 1)
        #expect(mismatchedIssues.first?.kind == .unbalancedDelimiter)
    }

    @Test("Live changed Swift files and configuration files pass diff-scoped lint gate")
    func liveChangedSwiftFilesPassGate() {
        let root = repoRootURL()
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swift-format").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".swiftlint.yml").path))

        let changed = SwiftSyntaxLintGate.changedSwiftFiles(in: root, baseRef: "origin/main")
        let filesToAudit = changed.isEmpty ? [root.appendingPathComponent("ApexAgent/Models/SwiftSyntaxLintGate.swift")] : changed
        let report = SwiftSyntaxLintGate.auditFiles(filesToAudit, relativeTo: root)
        #expect(report.passed, "Diff-scoped syntax/lint issues: \(report.formatSummary())")
        #expect(report.issues.isEmpty)
        #expect(report.formatSummary().hasPrefix("PASS:"))
    }
}
