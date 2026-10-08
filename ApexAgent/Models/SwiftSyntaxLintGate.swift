import Foundation

// MARK: - Batch 32: Diff-Scoped Swift Syntax, Format & Lint Gate

/// Kind of syntax, format, or lint violation detected by ``SwiftSyntaxLintGate``.
public enum SyntaxLintIssueKind: String, Codable, Sendable, CaseIterable {
    case mergeConflictMarker
    case unbalancedDelimiter
    case tabIndentation
    case duplicateImport
    case swiftFormatDiagnostic
}

/// A single syntax or lint violation in a Swift file.
public struct SyntaxLintIssue: Codable, Sendable, Equatable {
    public let kind: SyntaxLintIssueKind
    public let file: String
    public let line: Int
    public let message: String

    public init(kind: SyntaxLintIssueKind, file: String, line: Int, message: String) {
        self.kind = kind
        self.file = file
        self.line = line
        self.message = message
    }
}

/// Summary report from running ``SwiftSyntaxLintGate`` over a set of Swift files.
public struct SyntaxLintReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let checkedFiles: [String]
    public let issues: [SyntaxLintIssue]
    public let durationMs: Double

    public init(passed: Bool, checkedFiles: [String], issues: [SyntaxLintIssue], durationMs: Double) {
        self.passed = passed
        self.checkedFiles = checkedFiles
        self.issues = issues
        self.durationMs = durationMs
    }

    public func formatSummary() -> String {
        if passed {
            return String(format: "PASS: Swift syntax & lint gate clean (%d file(s) checked in %.1fms).", checkedFiles.count, durationMs)
        }
        var lines = [
            String(format: "FAIL: Swift syntax & lint gate found %d issue(s) across %d file(s) (%.1fms):", issues.count, checkedFiles.count, durationMs)
        ]
        for issue in issues {
            lines.append("  [\(issue.kind.rawValue)] \(issue.file):\(issue.line) — \(issue.message)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Diff-scoped Swift syntax, delimiter balance, conflict marker, and style validator.
public enum SwiftSyntaxLintGate {

    /// Analyzes a single Swift source string for conflict markers, duplicate imports, tab indentation, and unbalanced delimiters.
    public static func analyzeSwiftSource(_ source: String, filePath: String) -> [SyntaxLintIssue] {
        var issues: [SyntaxLintIssue] = []
        let lines = source.components(separatedBy: .newlines)
        var seenImports: [String: Int] = [:]
        var insideMultilineString = false

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Toggle multiline string state on """ occurrences
            let tripleQuoteCount = line.components(separatedBy: "\"\"\"").count - 1
            if tripleQuoteCount % 2 == 1 {
                insideMultilineString.toggle()
                continue
            }
            if insideMultilineString {
                continue
            }

            // 1. Merge conflict markers
            if line.hasPrefix("<<<<<<<") || line.hasPrefix("=======") || line.hasPrefix(">>>>>>>") {
                issues.append(
                    SyntaxLintIssue(
                        kind: .mergeConflictMarker,
                        file: filePath,
                        line: lineNum,
                        message: "Unresolved git merge conflict marker found."
                    )
                )
            }

            // 2. Leading tab indentation
            if let firstNonTab = line.firstIndex(where: { $0 != " " && $0 != "\t" }) {
                let indentPrefix = line[..<firstNonTab]
                if indentPrefix.contains("\t") {
                    issues.append(
                        SyntaxLintIssue(
                            kind: .tabIndentation,
                            file: filePath,
                            line: lineNum,
                            message: "Leading tab character in indentation; use 4 spaces."
                        )
                    )
                }
            }

            // 3. Duplicate top-level import statements (must start at column 0)
            if line.hasPrefix("import ") && !trimmed.contains("//") {
                let parts = trimmed.split(separator: " ").map(String.init)
                if parts.count == 2 {
                    let moduleName = parts[1]
                    if let firstLine = seenImports[moduleName] {
                        issues.append(
                            SyntaxLintIssue(
                                kind: .duplicateImport,
                                file: filePath,
                                line: lineNum,
                                message: "Duplicate 'import \(moduleName)' (already imported at line \(firstLine))."
                            )
                        )
                    } else {
                        seenImports[moduleName] = lineNum
                    }
                }
            }
        }

        // 4. Balanced brace/parenthesis/bracket check (ignoring comments and string literals)
        issues.append(contentsOf: checkBalancedDelimiters(in: source, filePath: filePath))

        return issues
    }

    private static func checkBalancedDelimiters(in source: String, filePath: String) -> [SyntaxLintIssue] {
        var stack: [(char: Character, line: Int)] = []
        let matchingOpen: [Character: Character] = ["}": "{", ")": "(", "]": "["]
        let openSet: Set<Character> = ["{", "(", "["]

        var inLineComment = false
        var inBlockComment = false
        var inRawString = false
        var inString = false
        var inMultilineString = false
        var escaped = false
        var currentLine = 1

        let chars = Array(source)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil
            let next2: Character? = (i + 2 < chars.count) ? chars[i + 2] : nil

            if c == "\n" {
                currentLine += 1
                inLineComment = false
                inRawString = false
                escaped = false
                i += 1
                continue
            }

            if inLineComment {
                i += 1
                continue
            }

            if inBlockComment {
                if c == "*" && next == "/" {
                    inBlockComment = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inRawString {
                if c == "\"" && next == "#" {
                    inRawString = false
                    i += 2
                    continue
                }
                i += 1
                continue
            }

            if inMultilineString {
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if c == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if c == "\"" && next == "\"" && next2 == "\"" {
                    inMultilineString = false
                    i += 3
                    continue
                }
                i += 1
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                    i += 1
                    continue
                }
                if c == "\\" {
                    escaped = true
                    i += 1
                    continue
                }
                if c == "\"" {
                    inString = false
                }
                i += 1
                continue
            }

            // Outside comments and strings
            if c == "/" && next == "/" {
                inLineComment = true
                i += 2
                continue
            }
            if c == "/" && next == "*" {
                inBlockComment = true
                i += 2
                continue
            }
            if c == "#" && next == "\"" {
                inRawString = true
                i += 2
                continue
            }
            if c == "\"" && next == "\"" && next2 == "\"" {
                inMultilineString = true
                i += 3
                continue
            }
            if c == "\"" {
                inString = true
                i += 1
                continue
            }

            if openSet.contains(c) {
                stack.append((c, currentLine))
            } else if let expectedOpen = matchingOpen[c] {
                guard let last = stack.popLast() else {
                    return [
                        SyntaxLintIssue(
                            kind: .unbalancedDelimiter,
                            file: filePath,
                            line: currentLine,
                            message: "Unexpected closing delimiter '\(c)' with no matching '\(expectedOpen)'."
                        )
                    ]
                }
                if last.char != expectedOpen {
                    return [
                        SyntaxLintIssue(
                            kind: .unbalancedDelimiter,
                            file: filePath,
                            line: currentLine,
                            message: "Mismatched closing delimiter '\(c)'; expected closing for '\(last.char)' opened at line \(last.line)."
                        )
                    ]
                }
            }

            i += 1
        }

        if let unclosed = stack.last {
            return [
                SyntaxLintIssue(
                    kind: .unbalancedDelimiter,
                    file: filePath,
                    line: unclosed.line,
                    message: "Unclosed delimiter '\(unclosed.char)' opened at line \(unclosed.line)."
                )
            ]
        }

        return []
    }

    /// Audits an explicit list of Swift file URLs and returns a ``SyntaxLintReport``.
    public static func auditFiles(_ fileURLs: [URL], relativeTo repoRoot: URL) -> SyntaxLintReport {
        let start = CFAbsoluteTimeGetCurrent()
        let canonicalRoot = repoRoot.resolvingSymlinksInPath().path
        var checked: [String] = []
        var allIssues: [SyntaxLintIssue] = []

        for url in fileURLs where url.pathExtension == "swift" {
            guard FileManager.default.fileExists(atPath: url.path),
                  let content = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let canonicalPath = url.resolvingSymlinksInPath().path
            let relPath = canonicalPath.replacingOccurrences(of: canonicalRoot + "/", with: "")
            checked.append(relPath)
            allIssues.append(contentsOf: analyzeSwiftSource(content, filePath: relPath))
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        return SyntaxLintReport(
            passed: allIssues.isEmpty,
            checkedFiles: checked,
            issues: allIssues,
            durationMs: durationMs
        )
    }

    /// Returns the `.swift` files modified between `baseRef` and `HEAD` (plus any working-tree changes).
    public static func changedSwiftFiles(in repoRoot: URL, baseRef: String = "origin/main") -> [URL] {
        let canonicalRoot = repoRoot.resolvingSymlinksInPath()
        var relativePaths = Set<String>()

        for args in [
            ["diff", "--name-only", "--diff-filter=ACMRTUXB", "\(baseRef)...HEAD", "--", "*.swift"],
            ["diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD", "--", "*.swift"]
        ] {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            proc.currentDirectoryURL = canonicalRoot
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let out = String(data: data, encoding: .utf8) {
                for line in out.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty && trimmed.hasSuffix(".swift") {
                        relativePaths.insert(trimmed)
                    }
                }
            }
        }

        return relativePaths.sorted().map { canonicalRoot.appendingPathComponent($0) }
    }
}
