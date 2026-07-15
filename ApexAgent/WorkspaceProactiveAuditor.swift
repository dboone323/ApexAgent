import Foundation
import SwiftData
import SharedKit

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
        return await Task.detached(priority: .background) {
            let fm = FileManager.default
            var results = [(file: String, line: Int, text: String)]()
            guard let regex = try? NSRegularExpression(pattern: "\\b(todo|fixme)\\b", options: [.caseInsensitive]) else {
                return results
            }
            let enumerator = fm.enumerator(atPath: path)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".swift") else { continue }
                if file.contains(".build") || file.contains(".git") || file.contains("Packages") { continue }
                
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
        return await Task.detached(priority: .background) {
            let fm = FileManager.default
            var sourceFiles = [String]()
            var testFiles = Set<String>()
            
            let enumerator = fm.enumerator(atPath: path)
            while let file = enumerator?.nextObject() as? String {
                guard file.hasSuffix(".swift") else { continue }
                if file.contains(".build") || file.contains(".git") { continue }
                
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
}
