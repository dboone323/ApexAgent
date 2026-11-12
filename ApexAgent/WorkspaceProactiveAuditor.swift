import Foundation
import SwiftData
import SharedKit
import os

public actor WorkspaceProactiveAuditor {
    public static let shared = WorkspaceProactiveAuditor()
    private let fileManager = FileManager.default
    private let customWorkspacePath: String?

    public init(workspacePath: String? = nil) {
        self.customWorkspacePath = workspacePath
    }

    private var workspacePath: String {
        if let custom = customWorkspacePath {
            return custom
        }
        // Check user-configured path first
        if let configured = UserDefaults.standard.string(forKey: "apex.workspacePath"),
           !configured.isEmpty,
           FileManager.default.fileExists(atPath: configured) {
            return configured
        }
        // Fall back to environment variable
        if let envPath = ProcessInfo.processInfo.environment["APEX_WORKSPACE"],
           !envPath.isEmpty {
            return envPath
        }
        // If testing, do not fall back to home Developer folder to avoid concurrency races scanning the whole folder
        let isTesting = ProcessInfo.processInfo.arguments.contains { $0.contains("test") || $0.contains("xctest") } || ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
        if isTesting {
            return FileManager.default.currentDirectoryPath
        }
        // Fall back to home directory Developer folder
        let devPath = NSHomeDirectory() + "/Developer"
        if FileManager.default.fileExists(atPath: devPath) {
            // Explicit warning: relying on the implicit ~/Developer fallback means the
            // workspace was not explicitly configured. Set apex.workspacePath or APEX_WORKSPACE
            // to make the audited scope unambiguous.
            let logger = Logger(subsystem: "com.apex.agent", category: "WorkspaceProactiveAuditor")
            logger.warning("WorkspaceProactiveAuditor falling back to implicit path \(devPath). Set apex.workspacePath (UserDefaults) or APEX_WORKSPACE to pin the audited workspace explicitly.")
            return devPath
        }
        // Last resort: process working directory
        return FileManager.default.currentDirectoryPath
    }

    public func performAudit(modelContext: ModelContext? = nil) async -> String {
        var report = "### 🔍 Workspace Proactive Audit Report\n\n"
        
        let todoItems = await findTodos()
        let testGapFiles = await findTestGaps()
        
        // Save findings to SwiftData database if available
        if let container = modelContext?.container {
            let backgroundContext = ModelContext(container)
            
            // Remove previous proactive audit sessions
            let desc = FetchDescriptor<ReviewSession>()
            if let sessions = try? backgroundContext.fetch(desc) {
                let proactiveSessions = sessions.filter { $0.fileName == "WorkspaceProactiveAudit" }
                for s in proactiveSessions {
                    backgroundContext.delete(s)
                }
            }
            
            var issues: [CodeIssueModel] = []
            for todo in todoItems {
                let filename = URL(fileURLWithPath: todo.file).lastPathComponent
                let issue = CodeIssueModel(line: todo.line, message: "[TODO] \(filename): \(todo.text)", severity: .info)
                issues.append(issue)
            }
            for gap in testGapFiles {
                let filename = URL(fileURLWithPath: gap).lastPathComponent
                let issue = CodeIssueModel(line: 1, message: "[TEST GAP] Uncovered file \(filename)", severity: .warning)
                issues.append(issue)
            }
            
            if !issues.isEmpty {
                let session = ReviewSession(
                    fileName: "WorkspaceProactiveAudit",
                    summary: "Proactive workspace scan: detected \(todoItems.count) TODOs and \(testGapFiles.count) test gaps.",
                    suggestions: ["Resolve pending TODOs", "Add unit tests for uncovered source files"]
                )
                session.issues = issues
                backgroundContext.insert(session)
                for issue in issues {
                    issue.session = session
                    backgroundContext.insert(issue)
                }
                try? backgroundContext.save()
            }
        }
        
        if todoItems.isEmpty && testGapFiles.isEmpty {
            report += "✅ No urgent code smells or test gaps found. Workspace is healthy!\n"
        } else {
            if !todoItems.isEmpty {
                report += "#### 📌 Pending Tasks (TODO/FIXME):\n"
                for (file, line, text) in todoItems.prefix(5) {
                    let filename = URL(fileURLWithPath: file).lastPathComponent
                    report += "- **\(filename):L\(line)**: `\(text)`\n"
                }
                if todoItems.count > 5 {
                    report += "- ... and \(todoItems.count - 5) more pending items.\n"
                }
                report += "\n"
            }
            
            if !testGapFiles.isEmpty {
                report += "#### 🧪 Test Coverage Gaps (source files without matching test files):\n"
                for file in testGapFiles.prefix(5) {
                    let filename = URL(fileURLWithPath: file).lastPathComponent
                    report += "- `\(filename)` needs unit tests.\n"
                }
                if testGapFiles.count > 5 {
                    report += "- ... and \(testGapFiles.count - 5) more source files lacking tests.\n"
                }
                report += "\n"
            }
        }
        return report
    }

    private func findTodos() async -> [(file: String, line: Int, text: String)] {
        let path = workspacePath
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var results = [(file: String, line: Int, text: String)]()
            guard let regex = try? NSRegularExpression(pattern: "\\b(todo|fixme)\\b", options: [.caseInsensitive]) else {
                return results
            }
            // Bound the scan so a large tree (e.g. the whole repo under test) can
            // never hang the caller. Real audits rely on an explicit, small scope.
            let maxFiles = 5000
            var scanned = 0
            let enumerator = fm.enumerator(atPath: path)
            while let file = enumerator?.nextObject() as? String {
                if Self.shouldSkip(path: file) {
                    enumerator?.skipDescendants()
                    continue
                }
                guard file.hasSuffix(".swift") else { continue }
                scanned += 1
                if scanned > maxFiles { break }
                let fullPath = URL(fileURLWithPath: path).appendingPathComponent(file).path
                guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }

                let lines = content.components(separatedBy: .newlines)
                for (idx, line) in lines.enumerated() {
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, options: [], range: range) != nil {
                        let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        results.append((file: fullPath, line: idx + 1, text: cleanLine))
                    }
                }
            }
            return results
        }.value
    }

    private func findTestGaps() async -> [String] {
        let path = workspacePath
        return await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var sourceFiles = [String]()
            var testFiles = Set<String>()

            let maxFiles = 5000
            var scanned = 0
            let enumerator = fm.enumerator(atPath: path)
            while let file = enumerator?.nextObject() as? String {
                if Self.shouldSkip(path: file) {
                    enumerator?.skipDescendants()
                    continue
                }
                guard file.hasSuffix(".swift") else { continue }
                scanned += 1
                if scanned > maxFiles { break }

                let filename = URL(fileURLWithPath: file).lastPathComponent
                if file.contains("Tests") {
                    let nameWithoutTests = filename.replacingOccurrences(of: "Tests.swift", with: "")
                                                  .replacingOccurrences(of: "Test.swift", with: "")
                    testFiles.insert(nameWithoutTests)
                } else {
                    let nameWithoutSuffix = filename.replacingOccurrences(of: ".swift", with: "")
                    if nameWithoutSuffix != "main" && nameWithoutSuffix != "AppDelegate" && nameWithoutSuffix != "ApexAgentApp" {
                        sourceFiles.append(file)
                    }
                }
            }

            return sourceFiles.filter { file in
                let nameWithoutSuffix = URL(fileURLWithPath: file).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
                return !testFiles.contains(nameWithoutSuffix)
            }
        }.value
    }

    /// True for build/derived/cache directories that should never be scanned.
    /// Checks path *components* (not a fragile substring) so nested matches work.
    private static func shouldSkip(path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents
        let skips = Set(["build", ".build", ".git", "node_modules", "Packages", "DerivedData", "xcuserdata"])
        return !skips.isDisjoint(with: components)
    }

    /// Returns a structured high-density Markdown summary table of proactive audit findings.
    public func formatAuditSummaryTable() async -> String {
        let todoItems = await findTodos()
        let testGapFiles = await findTestGaps()

        var md = "### 📊 Workspace Proactive Audit Summary\n\n"
        md += "| Metric / Category | Count | Status | Recommendation |\n"
        md += "|---|---|---|---|\n"

        let todoStatus = todoItems.isEmpty ? "🟢 Clean" : (todoItems.count > 10 ? "⚠️ Backlog" : "ℹ️ Normal")
        let todoRec = todoItems.isEmpty ? "None" : "Review and resolve active code comments"
        md += "| Pending TODO / FIXME Comments | `\(todoItems.count)` | \(todoStatus) | \(todoRec) |\n"

        let gapStatus = testGapFiles.isEmpty ? "🟢 Full Coverage" : (testGapFiles.count > 5 ? "⚠️ Gaps Detected" : "ℹ️ Minor Gaps")
        let gapRec = testGapFiles.isEmpty ? "None" : "Generate unit tests for uncovered components"
        md += "| Untested Source Files | `\(testGapFiles.count)` | \(gapStatus) | \(gapRec) |\n\n"

        if !todoItems.isEmpty {
            md += "#### 📋 Top Pending Items\n\n"
            md += "| Source File | Line | Snippet |\n"
            md += "|---|---|---|\n"
            for (file, line, text) in todoItems.prefix(5) {
                let filename = URL(fileURLWithPath: file).lastPathComponent.replacingOccurrences(of: "|", with: "\\|")
                let safeText = text.replacingOccurrences(of: "|", with: "\\|")
                md += "| `\(filename)` | `\(line)` | `\(safeText)` |\n"
            }
            md += "\n"
        }

        if !testGapFiles.isEmpty {
            md += "#### 🧪 Test Coverage Action Items\n\n"
            md += "| Untested Component | Proposed Test Suite |\n"
            md += "|---|---|\n"
            for gap in testGapFiles.prefix(5) {
                let filename = URL(fileURLWithPath: gap).lastPathComponent.replacingOccurrences(of: "|", with: "\\|")
                let testName = filename.replacingOccurrences(of: ".swift", with: "Tests.swift")
                md += "| `\(filename)` | `\(testName)` |\n"
            }
            md += "\n"
        }

        return md
    }

}