import Foundation

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

struct DiffHelper {
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
