import Foundation

// MARK: - Interactive PTY Terminal Security Gate (Batch 74)

/// Configuration policy for interactive terminal stream security.
public struct TerminalSecurityConfig: Sendable, Codable, Equatable {
    /// Disallow OSC 52 clipboard reading and writing escape sequences.
    public var blockClipboardEscapes: Bool
    /// Disallow OSC 0/2 window title manipulation escape sequences.
    public var blockTitleEscapes: Bool
    /// Disallow Device Status Report (DSR) CSI 6n input injection triggers.
    public var blockDeviceStatusReports: Bool
    /// Maximum allowed single-chunk stream size in bytes (prevent memory exhaustion).
    public var maxChunkBytes: Int
    /// Strip dangerous raw control characters (NUL, BEL, ENQ, etc.).
    public var stripControlCharacters: Bool

    public init(
        blockClipboardEscapes: Bool = true,
        blockTitleEscapes: Bool = true,
        blockDeviceStatusReports: Bool = true,
        maxChunkBytes: Int = 1_048_576, // 1 MB
        stripControlCharacters: Bool = true
    ) {
        self.blockClipboardEscapes = blockClipboardEscapes
        self.blockTitleEscapes = blockTitleEscapes
        self.blockDeviceStatusReports = blockDeviceStatusReports
        self.maxChunkBytes = maxChunkBytes
        self.stripControlCharacters = stripControlCharacters
    }
}

/// Category of terminal escape sequence violation.
public enum TerminalViolationKind: String, Sendable, Codable, Equatable {
    case clipboardEscapeInjection = "CLIPBOARD_ESCAPE_INJECTION"
    case titleEscapeManipulation = "TITLE_ESCAPE_MANIPULATION"
    case deviceStatusReportQuery = "DSR_INPUT_INJECTION_TRIGGER"
    case oversizedStreamChunk = "OVERSIZED_STREAM_CHUNK"
    case rawControlCharacter = "DANGEROUS_CONTROL_CHARACTER"
}

/// Violation detected in a terminal output stream.
public struct TerminalSecurityViolation: Sendable, Codable, Equatable {
    public let kind: TerminalViolationKind
    public let description: String
    public let snippet: String

    public init(kind: TerminalViolationKind, description: String, snippet: String) {
        self.kind = kind
        self.description = description
        self.snippet = snippet
    }
}

/// Detailed audit report for terminal stream analysis.
public struct TerminalSecurityAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [TerminalSecurityViolation]
    public let rawByteCount: Int
    public let sanitizedByteCount: Int
    public let strippedSequencesCount: Int

    public init(
        passed: Bool,
        score: Double,
        violations: [TerminalSecurityViolation],
        rawByteCount: Int,
        sanitizedByteCount: Int,
        strippedSequencesCount: Int
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.rawByteCount = rawByteCount
        self.sanitizedByteCount = sanitizedByteCount
        self.strippedSequencesCount = strippedSequencesCount
    }
}

/// Result of terminal stream sanitization.
public struct TerminalSanitizationResult: Sendable, Equatable {
    public let originalText: String
    public let sanitizedText: String
    public let report: TerminalSecurityAuditReport
}

/// Security sanitizer and auditor for interactive PTY and terminal outputs.
public enum TerminalSecurityGate {

    // Regex patterns for dangerous ANSI / OSC escape sequences
    // OSC 52 clipboard: ESC ] 52 ; ... (BEL | ESC \)
    private static let osc52Pattern = #"\x1B\]52;[^\x07\x1B]*(\x07|\x1B\\)?"#
    // OSC 0/2 window title: ESC ] (0|2) ; ... (BEL | ESC \)
    private static let oscTitlePattern = #"\x1B\][02];[^\x07\x1B]*(\x07|\x1B\\)?"#
    // CSI 6n Device Status Report: ESC [ 6 n
    private static let dsrPattern = #"\x1B\[6n"#
    // Dangerous control characters (ASCII 0x00..0x08, 0x0B..0x0C, 0x0E..0x1A, excluding \t, \n, \r, ESC)
    private static let controlCharsPattern = #"[\x00-\x08\x0B\x0C\x0E-\x1A]"#

    /// Audits and sanitizes an interactive terminal stream chunk.
    public static func sanitize(
        _ rawText: String,
        config: TerminalSecurityConfig = TerminalSecurityConfig()
    ) -> TerminalSanitizationResult {
        var violations: [TerminalSecurityViolation] = []
        var sanitized = rawText
        var strippedCount = 0

        let rawBytes = rawText.utf8.count
        if rawBytes > config.maxChunkBytes {
            violations.append(TerminalSecurityViolation(
                kind: .oversizedStreamChunk,
                description: "Terminal chunk size of \(rawBytes) bytes exceeds maximum ceiling of \(config.maxChunkBytes) bytes.",
                snippet: String(rawText.prefix(64))
            ))
            sanitized = String(sanitized.prefix(config.maxChunkBytes))
        }

        // 1. Detect & Strip OSC 52 Clipboard injection
        if config.blockClipboardEscapes {
            if let regex = try? NSRegularExpression(pattern: osc52Pattern, options: []) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                let matches = regex.matches(in: sanitized, options: [], range: range)
                if !matches.isEmpty {
                    for match in matches {
                        if let r = Range(match.range, in: sanitized) {
                            violations.append(TerminalSecurityViolation(
                                kind: .clipboardEscapeInjection,
                                description: "Detected OSC 52 clipboard manipulation escape sequence.",
                                snippet: String(sanitized[r])
                            ))
                        }
                    }
                    strippedCount += matches.count
                    sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
                }
            }
        }

        // 2. Detect & Strip OSC 0/2 Window Title hijacking
        if config.blockTitleEscapes {
            if let regex = try? NSRegularExpression(pattern: oscTitlePattern, options: []) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                let matches = regex.matches(in: sanitized, options: [], range: range)
                if !matches.isEmpty {
                    for match in matches {
                        if let r = Range(match.range, in: sanitized) {
                            violations.append(TerminalSecurityViolation(
                                kind: .titleEscapeManipulation,
                                description: "Detected OSC window title hijacking escape sequence.",
                                snippet: String(sanitized[r])
                            ))
                        }
                    }
                    strippedCount += matches.count
                    sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
                }
            }
        }

        // 3. Detect & Strip CSI 6n Device Status Report query
        if config.blockDeviceStatusReports {
            if let regex = try? NSRegularExpression(pattern: dsrPattern, options: []) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                let matches = regex.matches(in: sanitized, options: [], range: range)
                if !matches.isEmpty {
                    for match in matches {
                        if let r = Range(match.range, in: sanitized) {
                            violations.append(TerminalSecurityViolation(
                                kind: .deviceStatusReportQuery,
                                description: "Detected CSI 6n device status report sequence (potential input injection).",
                                snippet: String(sanitized[r])
                            ))
                        }
                    }
                    strippedCount += matches.count
                    sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
                }
            }
        }

        // 4. Strip dangerous control characters
        if config.stripControlCharacters {
            if let regex = try? NSRegularExpression(pattern: controlCharsPattern, options: []) {
                let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
                let matches = regex.matches(in: sanitized, options: [], range: range)
                if !matches.isEmpty {
                    violations.append(TerminalSecurityViolation(
                        kind: .rawControlCharacter,
                        description: "Stripped \(matches.count) raw control characters.",
                        snippet: "\(matches.count) control characters"
                    ))
                    strippedCount += matches.count
                    sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "")
                }
            }
        }

        let passed = violations.isEmpty
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 25.0)

        let report = TerminalSecurityAuditReport(
            passed: passed,
            score: score,
            violations: violations,
            rawByteCount: rawBytes,
            sanitizedByteCount: sanitized.utf8.count,
            strippedSequencesCount: strippedCount
        )

        return TerminalSanitizationResult(
            originalText: rawText,
            sanitizedText: sanitized,
            report: report
        )
    }

    /// Performs audit on a terminal string without modifying the text.
    public static func auditStream(
        rawOutput: String,
        config: TerminalSecurityConfig = TerminalSecurityConfig()
    ) -> TerminalSecurityAuditReport {
        sanitize(rawOutput, config: config).report
    }
}
