import Foundation

// MARK: - Code Coverage Threshold & Changed-File Coverage Gate (Batch 41)

/// Coverage metrics for a single source file.
public struct FileCoverageMetric: Sendable, Equatable, Codable {
    public let path: String
    public let coveredLines: Int
    public let executableLines: Int
    public let lineCoveragePercent: Double
    public let coveredFunctions: Int
    public let totalFunctions: Int
    public let functionCoveragePercent: Double

    public init(
        path: String,
        coveredLines: Int,
        executableLines: Int,
        lineCoveragePercent: Double,
        coveredFunctions: Int = 0,
        totalFunctions: Int = 0,
        functionCoveragePercent: Double = 100.0
    ) {
        self.path = path
        self.coveredLines = coveredLines
        self.executableLines = executableLines
        self.lineCoveragePercent = lineCoveragePercent
        self.coveredFunctions = coveredFunctions
        self.totalFunctions = totalFunctions
        self.functionCoveragePercent = functionCoveragePercent
    }
}

/// Aggregated coverage snapshot parsed from `llvm-cov export` or `xcrun xccov view --report --json`.
public struct CoverageSnapshot: Sendable, Equatable, Codable {
    public let format: String
    public let totalCoveredLines: Int
    public let totalExecutableLines: Int
    public let lineCoveragePercent: Double
    public let totalCoveredFunctions: Int
    public let totalFunctions: Int
    public let functionCoveragePercent: Double
    public let files: [FileCoverageMetric]

    public init(
        format: String,
        totalCoveredLines: Int,
        totalExecutableLines: Int,
        lineCoveragePercent: Double,
        totalCoveredFunctions: Int,
        totalFunctions: Int,
        functionCoveragePercent: Double,
        files: [FileCoverageMetric]
    ) {
        self.format = format
        self.totalCoveredLines = totalCoveredLines
        self.totalExecutableLines = totalExecutableLines
        self.lineCoveragePercent = lineCoveragePercent
        self.totalCoveredFunctions = totalCoveredFunctions
        self.totalFunctions = totalFunctions
        self.functionCoveragePercent = functionCoveragePercent
        self.files = files
    }
}

/// Evaluation result from enforcing project-wide and changed-file coverage budgets.
public struct CoverageGateEvaluation: Sendable, Equatable, Codable {
    public let passed: Bool
    public let overallLineCoveragePercent: Double
    public let minimumOverallLineCoveragePercent: Double
    public let overallFunctionCoveragePercent: Double
    public let minimumOverallFunctionCoveragePercent: Double
    public let minimumChangedFileCoveragePercent: Double
    public let evaluatedChangedFiles: [FileCoverageMetric]
    public let underCoveredChangedFiles: [FileCoverageMetric]
    public let findings: [String]

    public init(
        passed: Bool,
        overallLineCoveragePercent: Double,
        minimumOverallLineCoveragePercent: Double,
        overallFunctionCoveragePercent: Double,
        minimumOverallFunctionCoveragePercent: Double,
        minimumChangedFileCoveragePercent: Double,
        evaluatedChangedFiles: [FileCoverageMetric],
        underCoveredChangedFiles: [FileCoverageMetric],
        findings: [String]
    ) {
        self.passed = passed
        self.overallLineCoveragePercent = overallLineCoveragePercent
        self.minimumOverallLineCoveragePercent = minimumOverallLineCoveragePercent
        self.overallFunctionCoveragePercent = overallFunctionCoveragePercent
        self.minimumOverallFunctionCoveragePercent = minimumOverallFunctionCoveragePercent
        self.minimumChangedFileCoveragePercent = minimumChangedFileCoveragePercent
        self.evaluatedChangedFiles = evaluatedChangedFiles
        self.underCoveredChangedFiles = underCoveredChangedFiles
        self.findings = findings
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Code Coverage Gate (`\(badge)`)",
            "",
            "| Metric | Actual | Threshold | Status |",
            "| :--- | :---: | :---: | :---: |",
            String(
                format: "| **Overall Line Coverage** | %.2f%% | %.2f%% | %@ |",
                overallLineCoveragePercent,
                minimumOverallLineCoveragePercent,
                overallLineCoveragePercent + 1e-6 >= minimumOverallLineCoveragePercent ? "PASS" : "FAIL"
            ),
            String(
                format: "| **Overall Function Coverage** | %.2f%% | %.2f%% | %@ |",
                overallFunctionCoveragePercent,
                minimumOverallFunctionCoveragePercent,
                overallFunctionCoveragePercent + 1e-6 >= minimumOverallFunctionCoveragePercent ? "PASS" : "FAIL"
            ),
            String(
                format: "| **Changed Files Passing Floor (%.1f%%)** | %d / %d | 100%% | %@ |",
                minimumChangedFileCoveragePercent,
                evaluatedChangedFiles.count - underCoveredChangedFiles.count,
                evaluatedChangedFiles.count,
                underCoveredChangedFiles.isEmpty ? "PASS" : "FAIL"
            ),
        ]

        if !evaluatedChangedFiles.isEmpty {
            lines.append("")
            lines.append("### Changed-File Coverage")
            lines.append("| File | Covered / Executable | Line % | Function % | Status |")
            lines.append("| :--- | :---: | :---: | :---: | :---: |")
            for file in evaluatedChangedFiles {
                let filePass = file.lineCoveragePercent + 1e-6 >= minimumChangedFileCoveragePercent
                lines.append(
                    String(
                        format: "| `%@` | %d / %d | %.2f%% | %.2f%% | %@ |",
                        file.path,
                        file.coveredLines,
                        file.executableLines,
                        file.lineCoveragePercent,
                        file.functionCoveragePercent,
                        filePass ? "PASS" : "FAIL"
                    )
                )
            }
        }

        if !findings.isEmpty {
            lines.append("")
            lines.append("### Findings")
            for finding in findings {
                lines.append("- \(finding)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum CodeCoverageGateError: Error, LocalizedError, Equatable {
    case invalidJSON
    case unsupportedCoverageFormat

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Coverage payload is not valid JSON."
        case .unsupportedCoverageFormat:
            return "Coverage payload does not match llvm-cov export or xccov JSON schema."
        }
    }
}

public enum CodeCoverageGate {
    /// Parses either `llvm-cov export --summary-only` JSON or `xcrun xccov view --report --json` Data.
    public static func parseCoverageJSON(_ data: Data) throws -> CoverageSnapshot {
        guard let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodeCoverageGateError.invalidJSON
        }

        // 1. Check for `llvm-cov export` schema (`data: [{ totals: ..., files: ... }]`)
        if let dataArray = rawObject["data"] as? [[String: Any]],
           let firstExport = dataArray.first,
           let totals = firstExport["totals"] as? [String: Any] {
            return parseLLVMCov(firstExport: firstExport, totals: totals)
        }

        // 2. Check for `xccov view --report --json` schema (`lineCoverage`, `targets`)
        if rawObject["targets"] != nil || rawObject["lineCoverage"] != nil {
            return parseXCCov(root: rawObject)
        }

        throw CodeCoverageGateError.unsupportedCoverageFormat
    }

    private static func parseLLVMCov(firstExport: [String: Any], totals: [String: Any]) -> CoverageSnapshot {
        let linesDict = totals["lines"] as? [String: Any] ?? [:]
        let functionsDict = totals["functions"] as? [String: Any] ?? [:]

        let totalCoveredLines = linesDict["covered"] as? Int ?? 0
        let totalExecutableLines = linesDict["count"] as? Int ?? 0
        let linePercent = numericDouble(linesDict["percent"])
            ?? (totalExecutableLines > 0 ? (Double(totalCoveredLines) / Double(totalExecutableLines)) * 100.0 : 100.0)

        let totalCoveredFunctions = functionsDict["covered"] as? Int ?? 0
        let totalFunctions = functionsDict["count"] as? Int ?? 0
        let funcPercent = numericDouble(functionsDict["percent"])
            ?? (totalFunctions > 0 ? (Double(totalCoveredFunctions) / Double(totalFunctions)) * 100.0 : 100.0)

        var fileMetrics: [FileCoverageMetric] = []
        if let rawFiles = firstExport["files"] as? [[String: Any]] {
            for rawFile in rawFiles {
                guard let filename = rawFile["filename"] as? String else { continue }
                let summary = rawFile["summary"] as? [String: Any] ?? [:]
                let fLines = summary["lines"] as? [String: Any] ?? [:]
                let fFuncs = summary["functions"] as? [String: Any] ?? [:]

                let covLines = fLines["covered"] as? Int ?? 0
                let execLines = fLines["count"] as? Int ?? 0
                let fLinePct = numericDouble(fLines["percent"])
                    ?? (execLines > 0 ? (Double(covLines) / Double(execLines)) * 100.0 : 100.0)

                let covFuncs = fFuncs["covered"] as? Int ?? 0
                let countFuncs = fFuncs["count"] as? Int ?? 0
                let fFuncPct = numericDouble(fFuncs["percent"])
                    ?? (countFuncs > 0 ? (Double(covFuncs) / Double(countFuncs)) * 100.0 : 100.0)

                fileMetrics.append(
                    FileCoverageMetric(
                        path: filename,
                        coveredLines: covLines,
                        executableLines: execLines,
                        lineCoveragePercent: fLinePct,
                        coveredFunctions: covFuncs,
                        totalFunctions: countFuncs,
                        functionCoveragePercent: fFuncPct
                    )
                )
            }
        }

        return CoverageSnapshot(
            format: "llvm-cov",
            totalCoveredLines: totalCoveredLines,
            totalExecutableLines: totalExecutableLines,
            lineCoveragePercent: linePercent,
            totalCoveredFunctions: totalCoveredFunctions,
            totalFunctions: totalFunctions,
            functionCoveragePercent: funcPercent,
            files: fileMetrics.sorted { $0.path < $1.path }
        )
    }

    private static func parseXCCov(root: [String: Any]) -> CoverageSnapshot {
        let totalCoveredLines = root["coveredLines"] as? Int ?? 0
        let totalExecutableLines = root["executableLines"] as? Int ?? 0
        // xccov stores lineCoverage as 0.0...1.0 fraction
        let rawLineFraction = numericDouble(root["lineCoverage"]) ?? 0.0
        let linePercent = rawLineFraction <= 1.0 && totalExecutableLines > 0
            ? rawLineFraction * 100.0
            : rawLineFraction

        var fileMetrics: [FileCoverageMetric] = []
        var totalCoveredFuncs = 0
        var totalCountFuncs = 0

        if let targets = root["targets"] as? [[String: Any]] {
            for target in targets {
                let targetName = target["name"] as? String ?? ""
                if targetName.hasSuffix("Tests.xctest") || targetName.hasSuffix("UITests.xctest") {
                    continue
                }
                guard let files = target["files"] as? [[String: Any]] else { continue }
                for file in files {
                    let path = (file["path"] as? String) ?? (file["name"] as? String) ?? "unknown"
                    let covLines = file["coveredLines"] as? Int ?? 0
                    let execLines = file["executableLines"] as? Int ?? 0
                    let rawFraction = numericDouble(file["lineCoverage"]) ?? 0.0
                    let pct = rawFraction <= 1.0 && execLines > 0 ? rawFraction * 100.0 : rawFraction

                    let functions = file["functions"] as? [[String: Any]] ?? []
                    let countFuncs = functions.count
                    let covFuncs = functions.filter { ($0["executionCount"] as? Int ?? 0) > 0 }.count
                    totalCoveredFuncs += covFuncs
                    totalCountFuncs += countFuncs
                    let funcPct = countFuncs > 0 ? (Double(covFuncs) / Double(countFuncs)) * 100.0 : 100.0

                    fileMetrics.append(
                        FileCoverageMetric(
                            path: path,
                            coveredLines: covLines,
                            executableLines: execLines,
                            lineCoveragePercent: pct,
                            coveredFunctions: covFuncs,
                            totalFunctions: countFuncs,
                            functionCoveragePercent: funcPct
                        )
                    )
                }
            }
        }

        let overallFuncPct = totalCountFuncs > 0
            ? (Double(totalCoveredFuncs) / Double(totalCountFuncs)) * 100.0
            : 100.0

        return CoverageSnapshot(
            format: "xccov",
            totalCoveredLines: totalCoveredLines,
            totalExecutableLines: totalExecutableLines,
            lineCoveragePercent: linePercent,
            totalCoveredFunctions: totalCoveredFuncs,
            totalFunctions: totalCountFuncs,
            functionCoveragePercent: overallFuncPct,
            files: fileMetrics.sorted { $0.path < $1.path }
        )
    }

    private static func numericDouble(_ anyValue: Any?) -> Double? {
        if let d = anyValue as? Double { return d }
        if let n = anyValue as? NSNumber { return n.doubleValue }
        if let i = anyValue as? Int { return Double(i) }
        return nil
    }

    /// Evaluates a coverage snapshot against overall and changed-file minimum coverage thresholds.
    public static func evaluate(
        snapshot: CoverageSnapshot,
        changedFilePaths: [String] = [],
        minimumOverallLineCoverage: Double = 55.0,
        minimumOverallFunctionCoverage: Double = 50.0,
        minimumChangedFileCoverage: Double = 70.0
    ) -> CoverageGateEvaluation {
        var findings: [String] = []

        if snapshot.lineCoveragePercent + 1e-6 < minimumOverallLineCoverage {
            findings.append(
                String(
                    format: "Overall line coverage %.2f%% is below minimum floor %.2f%%.",
                    snapshot.lineCoveragePercent,
                    minimumOverallLineCoverage
                )
            )
        }

        if snapshot.functionCoveragePercent + 1e-6 < minimumOverallFunctionCoverage {
            findings.append(
                String(
                    format: "Overall function coverage %.2f%% is below minimum floor %.2f%%.",
                    snapshot.functionCoveragePercent,
                    minimumOverallFunctionCoverage
                )
            )
        }

        // Match changed file paths by suffix so relative git paths match absolute llvm-cov / xccov paths
        let normalizedChanged = changedFilePaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasSuffix(".swift") && !$0.contains("Tests/") }

        var evaluatedChanged: [FileCoverageMetric] = []
        var underCoveredChanged: [FileCoverageMetric] = []

        for changedPath in normalizedChanged {
            if let matched = snapshot.files.first(where: {
                $0.path == changedPath || $0.path.hasSuffix("/" + changedPath) || changedPath.hasSuffix("/" + $0.path)
            }) {
                evaluatedChanged.append(matched)
                if matched.executableLines > 0 && matched.lineCoveragePercent + 1e-6 < minimumChangedFileCoverage {
                    underCoveredChanged.append(matched)
                    findings.append(
                        String(
                            format: "Changed file '%@' has line coverage %.2f%% (below %.2f%% floor).",
                            changedPath,
                            matched.lineCoveragePercent,
                            minimumChangedFileCoverage
                        )
                    )
                }
            }
        }

        return CoverageGateEvaluation(
            passed: findings.isEmpty,
            overallLineCoveragePercent: snapshot.lineCoveragePercent,
            minimumOverallLineCoveragePercent: minimumOverallLineCoverage,
            overallFunctionCoveragePercent: snapshot.functionCoveragePercent,
            minimumOverallFunctionCoveragePercent: minimumOverallFunctionCoverage,
            minimumChangedFileCoveragePercent: minimumChangedFileCoverage,
            evaluatedChangedFiles: evaluatedChanged,
            underCoveredChangedFiles: underCoveredChanged,
            findings: findings
        )
    }
}
