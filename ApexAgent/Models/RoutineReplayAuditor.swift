import Foundation

// MARK: - Routine Recorder Deterministic Event Replay Gate (Batch 76)

/// Violation detected when auditing recorded routine steps for replay.
public struct RoutineReplayViolation: Sendable, Codable, Equatable {
    public let stepIndex: Int?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(stepIndex: Int? = nil, code: String, message: String, isFatal: Bool = true) {
        self.stepIndex = stepIndex
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by auditing a sequence of recorded steps for replay.
public struct RoutineReplayAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalStepsCount: Int
    public let isMonotonicOrdering: Bool
    public let isIdempotentSafe: Bool
    public let unboundVariables: [String]
    public let violations: [RoutineReplayViolation]

    public init(
        passed: Bool,
        score: Double,
        totalStepsCount: Int,
        isMonotonicOrdering: Bool,
        isIdempotentSafe: Bool,
        unboundVariables: [String],
        violations: [RoutineReplayViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalStepsCount = totalStepsCount
        self.isMonotonicOrdering = isMonotonicOrdering
        self.isIdempotentSafe = isIdempotentSafe
        self.unboundVariables = unboundVariables
        self.violations = violations
    }
}

/// Result of templated parameter substitution in a routine step.
public struct ParameterSubstitutionResult: Sendable, Equatable {
    public let originalText: String
    public let substitutedText: String
    public let substitutedKeys: [String]
    public let missingKeys: [String]
    public let isComplete: Bool
}

/// Auditor for routine recording sequences, parameter templates, and deterministic replay safety.
public enum RoutineReplayAuditor {

    public static let allowedActions: Set<String> = [
        "open_app", "shell", "applescript", "click", "click_coordinate", "key_press", "write_text", "wait", "note"
    ]

    private static let destructivePatterns = [
        "rm -rf", "rmdir", "mkfs", "dd if=", "> /dev/", "git reset --hard", "git clean -fdx", ":(){ :|:& };:"
    ]

    // MARK: - Step Sequence Audit

    /// Audits recorded steps for chronological monotonicity, known actions, idempotency risks, and unbound parameters.
    public static func auditSteps(
        steps: [RecordedStep],
        parameters: [String: String] = [:]
    ) -> RoutineReplayAuditReport {
        var violations: [RoutineReplayViolation] = []
        var isMonotonic = true
        var isIdempotentSafe = true
        var allUnboundVars: Set<String> = []

        guard !steps.isEmpty else {
            violations.append(RoutineReplayViolation(code: "EMPTY_ROUTINE", message: "Recorded routine contains zero steps."))
            return RoutineReplayAuditReport(
                passed: false,
                score: 0.0,
                totalStepsCount: 0,
                isMonotonicOrdering: false,
                isIdempotentSafe: false,
                unboundVariables: [],
                violations: violations
            )
        }

        var prevStep: RecordedStep?

        for (idx, step) in steps.enumerated() {
            // 1. Action validity
            if !allowedActions.contains(step.action) {
                violations.append(RoutineReplayViolation(
                    stepIndex: idx,
                    code: "UNKNOWN_ACTION_TYPE",
                    message: "Step action '\(step.action)' is not recognized for deterministic replay."
                ))
            }

            // 2. Monotonic timestamp check
            if let prev = prevStep {
                if step.occurredAt < prev.occurredAt {
                    isMonotonic = false
                    violations.append(RoutineReplayViolation(
                        stepIndex: idx,
                        code: "NON_MONOTONIC_TIMESTAMP",
                        message: "Step timestamp is earlier than previous step."
                    ))
                }

                // Debounce check: identical action & detail within 50ms
                let delta = step.occurredAt.timeIntervalSince(prev.occurredAt)
                if delta < 0.05 && step.action == prev.action && step.detail == prev.detail {
                    violations.append(RoutineReplayViolation(
                        stepIndex: idx,
                        code: "RAPID_DUPLICATE_STEP",
                        message: "Step is an undebounced duplicate of step \(idx - 1) (\(String(format: "%.1f", delta * 1000))ms apart).",
                        isFatal: false
                    ))
                }
            }

            // 3. Destructive command check
            if step.action == "shell" {
                for pattern in destructivePatterns {
                    if step.detail.contains(pattern) {
                        isIdempotentSafe = false
                        violations.append(RoutineReplayViolation(
                            stepIndex: idx,
                            code: "DESTRUCTIVE_SHELL_COMMAND",
                            message: "Step contains potentially non-reversible destructive pattern: '\(pattern)'."
                        ))
                    }
                }
            }

            // 4. Parameter template check
            let subResult = substituteParameters(text: step.detail, parameters: parameters)
            if !subResult.isComplete {
                for missing in subResult.missingKeys {
                    allUnboundVars.insert(missing)
                }
                violations.append(RoutineReplayViolation(
                    stepIndex: idx,
                    code: "UNBOUND_TEMPLATE_VARIABLES",
                    message: "Step detail contains unbound template variable(s): \(subResult.missingKeys.joined(separator: ", "))."
                ))
            }

            prevStep = step
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return RoutineReplayAuditReport(
            passed: passed,
            score: score,
            totalStepsCount: steps.count,
            isMonotonicOrdering: isMonotonic,
            isIdempotentSafe: isIdempotentSafe,
            unboundVariables: Array(allUnboundVars).sorted(),
            violations: violations
        )
    }

    // MARK: - Template Parameter Substitution

    /// Replaces `{{variable_name}}` templates with values from parameters dictionary.
    public static func substituteParameters(
        text: String,
        parameters: [String: String]
    ) -> ParameterSubstitutionResult {
        var result = text
        var substituted: [String] = []
        var missing: [String] = []

        // Regex for {{identifier}}
        let regex = try? NSRegularExpression(pattern: #"\{\{([a-zA-Z0-9_\-]+)\}\}"#, options: [])
        guard let regex else {
            return ParameterSubstitutionResult(
                originalText: text,
                substitutedText: text,
                substitutedKeys: [],
                missingKeys: [],
                isComplete: true
            )
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let varRange = match.range(at: 1)
            let varName = nsString.substring(with: varRange)

            if let val = parameters[varName] {
                substituted.append(varName)
                result = result.replacingOccurrences(of: "{{\(varName)}}", with: val)
            } else {
                missing.append(varName)
            }
        }

        return ParameterSubstitutionResult(
            originalText: text,
            substitutedText: result,
            substitutedKeys: substituted,
            missingKeys: missing,
            isComplete: missing.isEmpty
        )
    }
}
