import Foundation

// MARK: - File Patch Tool Fuzzy Chunk & Newline Normalization Gate (Batch 87)

/// Detected newline style across source text buffers.
public enum NewlineFormat: String, Sendable, Codable, Equatable {
    case lf = "\n"
    case crlf = "\r\n"
    case cr = "\r"
    case mixed = "mixed"
}

/// Strategy employed when matching patch target chunks in source buffers.
public enum FuzzyMatchStrategy: String, Sendable, Codable, Equatable {
    case exact
    case whitespaceNormalized
    case lineTrimmed
    case failed
}

/// Detailed result of attempting a fuzzy match for a target chunk.
public struct FuzzyMatchResult: Sendable, Codable, Equatable {
    public let matched: Bool
    public let confidence: Double
    public let strategy: FuzzyMatchStrategy
    public let matchedSubstring: String?

    public init(
        matched: Bool,
        confidence: Double,
        strategy: FuzzyMatchStrategy,
        matchedSubstring: String? = nil
    ) {
        self.matched = matched
        self.confidence = confidence
        self.strategy = strategy
        self.matchedSubstring = matchedSubstring
    }
}

/// Violation encountered during patch verification or application.
public struct FilePatchViolation: Sendable, Codable, Equatable {
    public let hunkIndex: Int?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(hunkIndex: Int? = nil, code: String, message: String, isFatal: Bool = true) {
        self.hunkIndex = hunkIndex
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Outcome of applying a patch with newline normalization and fuzzy resilience.
public struct PatchApplicationResult: Sendable, Codable, Equatable {
    public let success: Bool
    public let patchedContent: String
    public let detectedFormat: NewlineFormat
    public let retainedTrailingNewline: Bool
    public let appliedHunksCount: Int
    public let rejectedHunksCount: Int
    public let violations: [FilePatchViolation]

    public init(
        success: Bool,
        patchedContent: String,
        detectedFormat: NewlineFormat,
        retainedTrailingNewline: Bool,
        appliedHunksCount: Int,
        rejectedHunksCount: Int,
        violations: [FilePatchViolation]
    ) {
        self.success = success
        self.patchedContent = patchedContent
        self.detectedFormat = detectedFormat
        self.retainedTrailingNewline = retainedTrailingNewline
        self.appliedHunksCount = appliedHunksCount
        self.rejectedHunksCount = rejectedHunksCount
        self.violations = violations
    }
}

/// Auditor and resilient application engine for surgical file patching, CRLF normalization, and fuzzy matching.
public enum FilePatchResilienceAuditor {

    // MARK: - Newline Normalization

    /// Detects prevailing newline format in text buffer.
    public static func detectNewlineFormat(_ text: String) -> NewlineFormat {
        let crlfCount = text.components(separatedBy: "\r\n").count - 1
        let textWithoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
        let lfCount = textWithoutCRLF.components(separatedBy: "\n").count - 1
        let crCount = textWithoutCRLF.components(separatedBy: "\r").count - 1

        if crlfCount > 0 && lfCount == 0 && crCount == 0 {
            return .crlf
        } else if lfCount > 0 && crlfCount == 0 && crCount == 0 {
            return .lf
        } else if crCount > 0 && crlfCount == 0 && lfCount == 0 {
            return .cr
        } else if (crlfCount + lfCount + crCount) == 0 {
            return .lf // Default for single-line files
        } else {
            return .mixed
        }
    }

    /// Normalizes any text to uniform LF newlines while tracking trailing newline status.
    public static func normalizeToLF(_ text: String) -> (normalized: String, hadTrailingNewline: Bool) {
        let hadTrailing = text.hasSuffix("\r\n") || text.hasSuffix("\n") || text.hasSuffix("\r")
        var normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\r", with: "\n")
        return (normalized, hadTrailing)
    }

    /// Re-applies target newline formatting and preserves trailing newline convention.
    public static func restoreNewlines(
        _ text: String,
        format: NewlineFormat,
        retainTrailingNewline: Bool
    ) -> String {
        var base = text
        // Ensure base has no trailing newline before re-appending
        while base.hasSuffix("\r\n") || base.hasSuffix("\n") || base.hasSuffix("\r") {
            base.removeLast()
        }

        let lineEnding: String
        switch format {
        case .crlf: lineEnding = "\r\n"
        case .cr: lineEnding = "\r"
        case .lf, .mixed: lineEnding = "\n"
        }

        let lines = base.components(separatedBy: "\n")
        var restored = lines.joined(separator: lineEnding)

        if retainTrailingNewline {
            restored += lineEnding
        }
        return restored
    }

    // MARK: - Fuzzy Chunk Matching

    /// Attempts exact, whitespace-collapsed, and line-trimmed fuzzy matching for target content in source.
    public static func findFuzzyMatch(
        source: String,
        target: String
    ) -> FuzzyMatchResult {
        // 1. Exact match
        if source.contains(target) {
            return FuzzyMatchResult(
                matched: true,
                confidence: 1.0,
                strategy: .exact,
                matchedSubstring: target
            )
        }

        // 2. Whitespace-normalized match (trim internal indentation differences)
        let sourceLines = source.components(separatedBy: "\n")
        let targetLines = target.components(separatedBy: "\n")

        let trimmedTargetLines = targetLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !trimmedTargetLines.isEmpty && !trimmedTargetLines.allSatisfy(\.isEmpty) else {
            return FuzzyMatchResult(matched: false, confidence: 0.0, strategy: .failed)
        }

        let targetCount = trimmedTargetLines.count
        if sourceLines.count >= targetCount {
            for i in 0...(sourceLines.count - targetCount) {
                let candidateWindow = Array(sourceLines[i..<(i + targetCount)])
                let trimmedCandidate = candidateWindow.map { $0.trimmingCharacters(in: .whitespaces) }

                if trimmedCandidate == trimmedTargetLines {
                    // Match found with line-trimmed matching
                    let matchedOriginal = candidateWindow.joined(separator: "\n")
                    return FuzzyMatchResult(
                        matched: true,
                        confidence: 0.95,
                        strategy: .lineTrimmed,
                        matchedSubstring: matchedOriginal
                    )
                }
            }
        }

        return FuzzyMatchResult(matched: false, confidence: 0.0, strategy: .failed)
    }

    // MARK: - Resilient Patch Application

    /// Surgically applies target -> replacement in source with automatic CRLF normalization and fuzzy fallback.
    public static func applyPatch(
        source: String,
        target: String,
        replacement: String,
        allowMultiple: Bool = false
    ) -> PatchApplicationResult {
        var violations: [FilePatchViolation] = []

        if target.isEmpty {
            violations.append(FilePatchViolation(
                code: "EMPTY_TARGET_CONTENT",
                message: "Target content to replace cannot be empty."
            ))
            return PatchApplicationResult(
                success: false,
                patchedContent: source,
                detectedFormat: detectNewlineFormat(source),
                retainedTrailingNewline: source.hasSuffix("\r\n") || source.hasSuffix("\n") || source.hasSuffix("\r"),
                appliedHunksCount: 0,
                rejectedHunksCount: 1,
                violations: violations
            )
        }

        let format = detectNewlineFormat(source)
        let (normalizedSource, trailingNewline) = normalizeToLF(source)
        let (normalizedTarget, _) = normalizeToLF(target)
        let (normalizedReplacement, _) = normalizeToLF(replacement)

        let match = findFuzzyMatch(source: normalizedSource, target: normalizedTarget)

        guard match.matched, let matchedChunk = match.matchedSubstring else {
            violations.append(FilePatchViolation(
                code: "TARGET_NOT_FOUND",
                message: "Could not locate target content in source file using exact or fuzzy matching."
            ))
            return PatchApplicationResult(
                success: false,
                patchedContent: source,
                detectedFormat: format,
                retainedTrailingNewline: trailingNewline,
                appliedHunksCount: 0,
                rejectedHunksCount: 1,
                violations: violations
            )
        }

        let occurrences = normalizedSource.components(separatedBy: matchedChunk).count - 1
        if occurrences > 1 && !allowMultiple {
            violations.append(FilePatchViolation(
                code: "MULTIPLE_MATCHES_DISALLOWED",
                message: "Found \(occurrences) matches for target content. Set allowMultiple=true to replace all."
            ))
            return PatchApplicationResult(
                success: false,
                patchedContent: source,
                detectedFormat: format,
                retainedTrailingNewline: trailingNewline,
                appliedHunksCount: 0,
                rejectedHunksCount: occurrences,
                violations: violations
            )
        }

        let newNormalized: String
        if allowMultiple {
            newNormalized = normalizedSource.replacingOccurrences(of: matchedChunk, with: normalizedReplacement)
        } else {
            if let range = normalizedSource.range(of: matchedChunk) {
                var s = normalizedSource
                s.replaceSubrange(range, with: normalizedReplacement)
                newNormalized = s
            } else {
                newNormalized = normalizedSource
            }
        }

        let restoredResult = restoreNewlines(newNormalized, format: format, retainTrailingNewline: trailingNewline)

        return PatchApplicationResult(
            success: true,
            patchedContent: restoredResult,
            detectedFormat: format,
            retainedTrailingNewline: trailingNewline,
            appliedHunksCount: occurrences,
            rejectedHunksCount: 0,
            violations: violations
        )
    }
}
