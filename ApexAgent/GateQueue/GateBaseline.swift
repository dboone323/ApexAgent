import Foundation

/// Represents a project's recorded gate baseline:
/// expected summary totals and known non-green noise patterns.
public struct GateBaseline: Codable, Sendable, Equatable {
    public var totalTests: Int?
    public var passed: Int?
    public var failed: Int?
    public var skipped: Int?
    public var knownNoisePatterns: [String]

    public init(
        totalTests: Int? = nil,
        passed: Int? = nil,
        failed: Int? = nil,
        skipped: Int? = nil,
        knownNoisePatterns: [String] = []
    ) {
        self.totalTests = totalTests
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.knownNoisePatterns = knownNoisePatterns
    }

    /// Load baseline from a file URL (supporting both JSON and plaintext / markdown).
    public static func load(from url: URL) throws -> GateBaseline {
        let data = try Data(contentsOf: url)
        if let json = try? JSONDecoder().decode(GateBaseline.self, from: data) {
            return json
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return GateBaseline()
        }
        return parse(text: text)
    }

    /// Parses markdown or plaintext content containing summary totals and noise patterns.
    public static func parse(text: String) -> GateBaseline {
        var baseline = GateBaseline()
        let lines = text.components(separatedBy: .newlines)

        // Regex for totals: e.g. "1893 total / 1878 passed / 0 failed / 15 skipped"
        let totalsPattern = try? NSRegularExpression(
            pattern: #"(\d+)\s+total\s*/\s*(\d+)\s+passed\s*/\s*(\d+)\s+failed\s*/\s*(\d+)\s+skipped"#,
            options: .caseInsensitive
        )

        var noisePatterns: [String] = []
        var inNoiseSection = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // Check for totals line
            if let pattern = totalsPattern {
                let range = NSRange(line.startIndex..., in: line)
                if let match = pattern.firstMatch(in: line, range: range) {
                    if let r1 = Range(match.range(at: 1), in: line),
                       let r2 = Range(match.range(at: 2), in: line),
                       let r3 = Range(match.range(at: 3), in: line),
                       let r4 = Range(match.range(at: 4), in: line) {
                        baseline.totalTests = Int(line[r1])
                        baseline.passed = Int(line[r2])
                        baseline.failed = Int(line[r3])
                        baseline.skipped = Int(line[r4])
                    }
                }
            }

            // Check for section headers
            let lower = line.lowercased()
            if lower.contains("noise") || lower.contains("known alert") || lower.contains("known warnings") {
                inNoiseSection = true
                continue
            } else if line.hasPrefix("#") {
                inNoiseSection = false
            }

            // Capture noise patterns
            if inNoiseSection {
                let cleaned = line
                    .replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "^`|`$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty && !cleaned.hasPrefix("#") {
                    noisePatterns.append(cleaned)
                }
            } else if line.hasPrefix("- noise:") || line.hasPrefix("noise:") {
                let cleaned = line
                    .replacingOccurrences(of: "^[-*•]?\\s*noise:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
                if !cleaned.isEmpty {
                    noisePatterns.append(cleaned)
                }
            }
        }

        baseline.knownNoisePatterns = noisePatterns
        return baseline
    }

    /// Check if a log line matches any of the known noise patterns.
    public func matchesKnownNoise(_ lineText: String) -> String? {
        for pattern in knownNoisePatterns {
            if pattern.isEmpty { continue }
            if lineText.localizedCaseInsensitiveContains(pattern) {
                return pattern
            }
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(lineText.startIndex..., in: lineText)
                if regex.firstMatch(in: lineText, range: range) != nil {
                    return pattern
                }
            }
        }
        return nil
    }
}
