import Foundation

struct DiffHelper {
    struct DiffLine: Identifiable, Sendable {
        let id = UUID()
        enum Kind: Sendable {
            case unchanged
            case added
            case deleted
        }
        let kind: Kind
        let text: String
        let lineNumber: Int?
    }

    static func computeDiff(oldText: String, newText: String) -> [DiffLine] {
        let oldLines = oldText.components(separatedBy: .newlines)
        let newLines = newText.components(separatedBy: .newlines)
        
        let m = oldLines.count
        let n = newLines.count
        
        // DP table for LCS
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        
        for i in 1...m {
            for j in 1...n {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        
        var diff: [DiffLine] = []
        var i = m
        var j = n
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                diff.append(DiffLine(kind: .unchanged, text: oldLines[i - 1], lineNumber: i))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                diff.append(DiffLine(kind: .added, text: newLines[j - 1], lineNumber: nil))
                j -= 1
            } else if i > 0 && (j == 0 || dp[i][j - 1] < dp[i - 1][j]) {
                diff.append(DiffLine(kind: .deleted, text: oldLines[i - 1], lineNumber: i))
                i -= 1
            }
        }
        
        return diff.reversed()
    }
}


public struct DiffStats: Sendable, Equatable {
    public let additions: Int
    public let deletions: Int
    public let unchanged: Int

    public var netChange: Int { additions - deletions }
    public var totalLines: Int { additions + deletions + unchanged }

    public func summary() -> String {
        "+\(additions), -\(deletions) (net \(netChange >= 0 ? "+\(netChange)" : "\(netChange)"))"
    }
}

extension DiffHelper {
    public static func computeStats(diff: [DiffLine]) -> DiffStats {
        var add = 0
        var del = 0
        var unc = 0
        for line in diff {
            switch line.kind {
            case .added: add += 1
            case .deleted: del += 1
            case .unchanged: unc += 1
            }
        }
        return DiffStats(additions: add, deletions: del, unchanged: unc)
    }

    public static func formatUnifiedDiff(oldText: String, newText: String, filePath: String) -> String {
        let diff = computeDiff(oldText: oldText, newText: newText)
        let stats = computeStats(diff: diff)

        var header = "--- a/\(filePath)\n+++ b/\(filePath)\n"
        header += "@@ -1,\(oldText.components(separatedBy: .newlines).count) +1,\(newText.components(separatedBy: .newlines).count) @@ [\(stats.summary())]\n"

        var lines: [String] = []
        for line in diff {
            switch line.kind {
            case .unchanged:
                lines.append(" \(line.text)")
            case .added:
                lines.append("+\(line.text)")
            case .deleted:
                lines.append("-\(line.text)")
            }
        }
        return header + lines.joined(separator: "\n")
    }
}

extension DiffStats {
    public var badge: String {
        if additions == 0 && deletions == 0 { return "⚪️ No Changes" }
        if deletions == 0 { return "🟢 Additions Only" }
        if additions == 0 { return "🟠 Deletions Only" }
        return "🔵 Mixed Changes"
    }

    public func formatAsMarkdownRow(filePath: String) -> String {
        "| `\(filePath)` | `+\(additions)` | `-\(deletions)` | \(badge) | `\(summary())` |"
    }
}

extension DiffHelper.DiffLine.Kind {
    public var prefix: String {
        switch self {
        case .unchanged: return " "
        case .added: return "+"
        case .deleted: return "-"
        }
    }
}

extension DiffHelper.DiffLine {
    public func formatTruncated(maxWidth: Int = 160) -> String {
        let text = text.count > maxWidth ? String(text.prefix(maxWidth)) + "…" : text
        return "\(kind.prefix)\(text)"
    }
}

