import Foundation

// MARK: - Workspace Footprint, Asset Size & Source Complexity Budget Gate (Batch 48)

/// Footprint breakdown for a single top-level subsystem directory under `ApexAgent/`.
public struct SubsystemFootprintMetric: Sendable, Equatable, Codable {
    public let subsystem: String
    public let fileCount: Int
    public let totalLines: Int
    public let totalBytes: Int
    public let largestFile: String
    public let largestFileLines: Int

    public init(
        subsystem: String,
        fileCount: Int,
        totalLines: Int,
        totalBytes: Int,
        largestFile: String,
        largestFileLines: Int
    ) {
        self.subsystem = subsystem
        self.fileCount = fileCount
        self.totalLines = totalLines
        self.totalBytes = totalBytes
        self.largestFile = largestFile
        self.largestFileLines = largestFileLines
    }
}

/// Records a file or asset that exceeded its configured line-count or byte-size budget.
public struct OversizedArtifactItem: Sendable, Equatable, Codable {
    public let path: String
    public let lineCount: Int
    public let byteSize: Int
    public let reason: String

    public init(path: String, lineCount: Int, byteSize: Int, reason: String) {
        self.path = path
        self.lineCount = lineCount
        self.byteSize = byteSize
        self.reason = reason
    }
}

/// Complete workspace footprint and complexity budget report.
public struct ArtifactSizeBudgetReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let totalSwiftFiles: Int
    public let totalSwiftLines: Int
    public let totalSwiftBytes: Int
    public let totalResourceBytes: Int
    public let maxSingleSwiftFileLines: Int
    public let maxSingleResourceBytes: Int
    public let maxTotalSourceBytes: Int
    public let subsystems: [SubsystemFootprintMetric]
    public let violations: [OversizedArtifactItem]

    public init(
        passed: Bool,
        totalSwiftFiles: Int,
        totalSwiftLines: Int,
        totalSwiftBytes: Int,
        totalResourceBytes: Int,
        maxSingleSwiftFileLines: Int,
        maxSingleResourceBytes: Int,
        maxTotalSourceBytes: Int,
        subsystems: [SubsystemFootprintMetric],
        violations: [OversizedArtifactItem]
    ) {
        self.passed = passed
        self.totalSwiftFiles = totalSwiftFiles
        self.totalSwiftLines = totalSwiftLines
        self.totalSwiftBytes = totalSwiftBytes
        self.totalResourceBytes = totalResourceBytes
        self.maxSingleSwiftFileLines = maxSingleSwiftFileLines
        self.maxSingleResourceBytes = maxSingleResourceBytes
        self.maxTotalSourceBytes = maxTotalSourceBytes
        self.subsystems = subsystems
        self.violations = violations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Workspace Footprint & Complexity Budget Gate (`\(badge)`)",
            "",
            "- **Total Swift Files**: `\(totalSwiftFiles)` (`\(totalSwiftLines)` lines, `\(totalSwiftBytes)` bytes)",
            "- **Total Resource Bytes**: `\(totalResourceBytes)` bytes",
            "- **Single Swift File Cap**: `\(maxSingleSwiftFileLines)` lines",
            "- **Single Resource Cap**: `\(maxSingleResourceBytes)` bytes",
            "",
            "| Subsystem | Files | Total Lines | Total Bytes | Largest File | Max Lines |",
            "| :--- | :---: | :---: | :---: | :--- | :---: |",
        ]
        for sub in subsystems {
            lines.append(
                "| **\(sub.subsystem)** | \(sub.fileCount) | \(sub.totalLines) | \(sub.totalBytes) | `\(sub.largestFile)` | \(sub.largestFileLines) |"
            )
        }
        if !violations.isEmpty {
            lines.append("")
            lines.append("### Budget Violations")
            for v in violations {
                lines.append("- `\(v.path)` (\(v.lineCount) lines, \(v.byteSize) bytes): \(v.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ArtifactSizeBudgetGate {
    /// Audits the `ApexAgent/` source tree and `ApexAgent/Resources/` directory at `rootURL`.
    ///
    /// - Parameters:
    ///   - rootURL: The repository root URL. Standardized and symlink-resolved to reliably audit
    ///     worktrees created in symlinked paths (e.g. `/tmp` -> `/private/tmp`).
    ///   - maxSingleSwiftFileLines: Single file line complexity budget (default 2500; largest file
    ///     is `AgentOrchestrator.swift` at 1929 lines after PR #162 / issue #101 sub-agent additions).
    ///   - maxSingleResourceBytes: Single resource asset budget (default 2,000,000 bytes; largest is
    ///     `ToolSchemas.json` at ~79 KB).
    ///   - maxTotalSourceBytes: Total Swift source byte budget (default 10,000,000 bytes; current
    ///     verified footprint is ~3.96 MB across 365 Swift files and 97,464 lines after PRs #77, #80,
    ///     #86, #153, #155, and #162).
    public static func auditWorkspaceFootprint(
        atRepoRoot rootURL: URL,
        maxSingleSwiftFileLines: Int = 2500,
        maxSingleResourceBytes: Int = 2_000_000,
        maxTotalSourceBytes: Int = 10_000_000
    ) -> ArtifactSizeBudgetReport {
        let normalizedRootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = normalizedRootURL.path.hasSuffix("/") ? normalizedRootURL.path : normalizedRootURL.path + "/"
        let apexDir = normalizedRootURL.appendingPathComponent("ApexAgent")
        var fileEntries: [(relativePath: String, lineCount: Int, byteSize: Int, isResource: Bool)] = []

        if let enumerator = FileManager.default.enumerator(
            at: apexDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else {
                    continue
                }
                let normalizedFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
                let filePath = normalizedFileURL.path
                let relPath = filePath.hasPrefix(rootPath)
                    ? String(filePath.dropFirst(rootPath.count))
                    : filePath.replacingOccurrences(of: rootPath, with: "")
                let byteSize = values.fileSize ?? 0
                if fileURL.pathExtension == "swift" {
                    let content = (try? String(contentsOf: normalizedFileURL, encoding: .utf8)) ?? ""
                    let lineCount = content.isEmpty ? 0 : content.components(separatedBy: .newlines).count
                    fileEntries.append((relPath, lineCount, byteSize, false))
                } else if relPath.hasPrefix("ApexAgent/Resources/") {
                    fileEntries.append((relPath, 0, byteSize, true))
                }
            }
        }

        return evaluate(
            entries: fileEntries,
            maxSingleSwiftFileLines: maxSingleSwiftFileLines,
            maxSingleResourceBytes: maxSingleResourceBytes,
            maxTotalSourceBytes: maxTotalSourceBytes
        )
    }

    /// Evaluates a list of file footprint entries against line and byte budgets.
    public static func evaluate(
        entries: [(relativePath: String, lineCount: Int, byteSize: Int, isResource: Bool)],
        maxSingleSwiftFileLines: Int = 2500,
        maxSingleResourceBytes: Int = 2_000_000,
        maxTotalSourceBytes: Int = 10_000_000
    ) -> ArtifactSizeBudgetReport {
        var totalSwiftFiles = 0
        var totalSwiftLines = 0
        var totalSwiftBytes = 0
        var totalResourceBytes = 0
        var violations: [OversizedArtifactItem] = []

        var groupedBySubsystem: [String: [(path: String, lines: Int, bytes: Int)]] = [:]

        for entry in entries {
            if entry.isResource {
                totalResourceBytes += entry.byteSize
                if entry.byteSize > maxSingleResourceBytes {
                    violations.append(
                        OversizedArtifactItem(
                            path: entry.relativePath,
                            lineCount: 0,
                            byteSize: entry.byteSize,
                            reason: "Resource size \(entry.byteSize)B exceeds \(maxSingleResourceBytes)B budget."
                        )
                    )
                }
            } else {
                totalSwiftFiles += 1
                totalSwiftLines += entry.lineCount
                totalSwiftBytes += entry.byteSize

                let parts = entry.relativePath.split(separator: "/")
                let subsystem = parts.count >= 3 ? String(parts[1]) : "Root"
                groupedBySubsystem[subsystem, default: []].append(
                    (path: entry.relativePath, lines: entry.lineCount, bytes: entry.byteSize)
                )

                if entry.lineCount > maxSingleSwiftFileLines {
                    violations.append(
                        OversizedArtifactItem(
                            path: entry.relativePath,
                            lineCount: entry.lineCount,
                            byteSize: entry.byteSize,
                            reason: "Swift file line count \(entry.lineCount) exceeds \(maxSingleSwiftFileLines)-line complexity budget."
                        )
                    )
                }
            }
        }

        if totalSwiftBytes > maxTotalSourceBytes {
            violations.append(
                OversizedArtifactItem(
                    path: "ApexAgent/",
                    lineCount: totalSwiftLines,
                    byteSize: totalSwiftBytes,
                    reason: "Total Swift source footprint \(totalSwiftBytes)B exceeds \(maxTotalSourceBytes)B budget."
                )
            )
        }

        var subsystemMetrics: [SubsystemFootprintMetric] = []
        for (subsystem, items) in groupedBySubsystem {
            let sumLines = items.reduce(0) { $0 + $1.lines }
            let sumBytes = items.reduce(0) { $0 + $1.bytes }
            let largest = items.max(by: { $0.lines < $1.lines })
            subsystemMetrics.append(
                SubsystemFootprintMetric(
                    subsystem: subsystem,
                    fileCount: items.count,
                    totalLines: sumLines,
                    totalBytes: sumBytes,
                    largestFile: largest?.path ?? "",
                    largestFileLines: largest?.lines ?? 0
                )
            )
        }
        subsystemMetrics.sort { $0.totalLines > $1.totalLines }

        return ArtifactSizeBudgetReport(
            passed: violations.isEmpty,
            totalSwiftFiles: totalSwiftFiles,
            totalSwiftLines: totalSwiftLines,
            totalSwiftBytes: totalSwiftBytes,
            totalResourceBytes: totalResourceBytes,
            maxSingleSwiftFileLines: maxSingleSwiftFileLines,
            maxSingleResourceBytes: maxSingleResourceBytes,
            maxTotalSourceBytes: maxTotalSourceBytes,
            subsystems: subsystemMetrics,
            violations: violations
        )
    }
}
