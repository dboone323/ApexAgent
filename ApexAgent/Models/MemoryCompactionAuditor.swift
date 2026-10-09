import Foundation
import SharedKit

// MARK: - Cognitive Memory Compaction & Semantic Vector Integrity Gate (Batch 55)

/// Severity of a memory integrity violation.
public enum MemoryViolationSeverity: String, Codable, Sendable, Comparable {
    case info = "INFO"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"

    private var rank: Int {
        switch self {
        case .info: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: MemoryViolationSeverity, rhs: MemoryViolationSeverity) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// Retention and compaction configuration policies for cognitive memory subsystems.
public struct MemoryCompactionPolicy: Codable, Sendable, Equatable {
    public let maxWorkingContextBytes: Int
    public let maxEpisodicEntriesPerBot: Int
    public let minEmbeddingDimensions: Int
    public let archiveThreshold: Int

    public init(
        maxWorkingContextBytes: Int = 64 * 1024,
        maxEpisodicEntriesPerBot: Int = 1000,
        minEmbeddingDimensions: Int = 64,
        archiveThreshold: Int = 500
    ) {
        self.maxWorkingContextBytes = maxWorkingContextBytes
        self.maxEpisodicEntriesPerBot = maxEpisodicEntriesPerBot
        self.minEmbeddingDimensions = minEmbeddingDimensions
        self.archiveThreshold = archiveThreshold
    }
}

/// A specific defect detected in working, episodic, or semantic vector memory.
public struct MemoryIntegrityViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(botId):\(ruleId):\(message)" }
    public let botId: String
    public let ruleId: String
    public let severity: MemoryViolationSeverity
    public let message: String
    public let remediation: String

    public init(
        botId: String,
        ruleId: String,
        severity: MemoryViolationSeverity,
        message: String,
        remediation: String
    ) {
        self.botId = botId
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Outcome of a memory compaction operation for a specific bot.
public struct MemoryCompactionResult: Codable, Sendable, Equatable {
    public let botId: String
    public let preCompactionEntries: Int
    public let postCompactionEntries: Int
    public let archivedEntries: Int
    public let preCompactionBytes: Int
    public let postCompactionBytes: Int
    public let compactionRatio: Double

    public init(
        botId: String,
        preCompactionEntries: Int,
        postCompactionEntries: Int,
        archivedEntries: Int,
        preCompactionBytes: Int,
        postCompactionBytes: Int
    ) {
        self.botId = botId
        self.preCompactionEntries = preCompactionEntries
        self.postCompactionEntries = postCompactionEntries
        self.archivedEntries = archivedEntries
        self.preCompactionBytes = preCompactionBytes
        self.postCompactionBytes = postCompactionBytes
        let initial = Double(max(preCompactionBytes, 1))
        self.compactionRatio = Double(postCompactionBytes) / initial
    }
}

/// Aggregated report of cognitive memory health and compaction integrity.
public struct MemoryCompactionAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedBots: Int
    public let violations: [MemoryIntegrityViolation]
    public let compactionSummaries: [MemoryCompactionResult]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedBots: Int,
        violations: [MemoryIntegrityViolation],
        compactionSummaries: [MemoryCompactionResult],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedBots = evaluatedBots
        self.violations = violations
        self.compactionSummaries = compactionSummaries
        self.recommendations = recommendations
    }

    public func toMarkdown() -> String {
        let badge = passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## Cognitive Memory Compaction & Vector Integrity Audit (`\(badge)`)",
            "",
            "- **Integrity Score**: `\(String(format: "%.1f", score))/100.0`",
            "- **Bots Evaluated**: `\(evaluatedBots)`",
            "- **Violations Detected**: `\(violations.count)`",
            ""
        ]

        if !compactionSummaries.isEmpty {
            lines.append("### Compaction Summaries")
            lines.append("| Bot ID | Pre-Entries | Post-Entries | Archived | Pre (Bytes) | Post (Bytes) | Ratio |")
            lines.append("| :--- | :---: | :---: | :---: | :---: | :---: | :---: |")
            for c in compactionSummaries {
                let ratioPercent = String(format: "%.1f%%", c.compactionRatio * 100.0)
                lines.append("| `\(c.botId.prefix(8))` | \(c.preCompactionEntries) | \(c.postCompactionEntries) | \(c.archivedEntries) | \(c.preCompactionBytes) | \(c.postCompactionBytes) | \(ratioPercent) |")
            }
            lines.append("")
        }

        if !violations.isEmpty {
            lines.append("### Violations")
            lines.append("| Bot ID | Rule ID | Severity | Violation | Remediation |")
            lines.append("| :--- | :--- | :---: | :--- | :--- |")
            for v in violations {
                lines.append("| `\(v.botId.prefix(8))` | `\(v.ruleId)` | `\(v.severity.rawValue)` | \(v.message) | \(v.remediation) |")
            }
            lines.append("")
        }

        if !recommendations.isEmpty {
            lines.append("### Hardening Recommendations")
            for r in recommendations {
                lines.append("- \(r)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

/// Auditor and compaction engine for bot working memory, episodic logs, and semantic vectors.
public enum MemoryCompactionAuditor {
    /// Compresses and partitions episodic entries into retained and archived tiers according to capacity limits.
    public static func compactEpisodes(
        _ episodes: [CognitiveMemoryEngine.EpisodicEntry],
        maxLimit: Int
    ) -> (retained: [CognitiveMemoryEngine.EpisodicEntry], archived: [CognitiveMemoryEngine.EpisodicEntry]) {
        guard episodes.count > maxLimit else {
            return (episodes, [])
        }
        let sorted = episodes.sorted { $0.timestamp < $1.timestamp }
        let archiveCount = sorted.count - maxLimit
        let archived = Array(sorted.prefix(archiveCount))
        let retained = Array(sorted.suffix(maxLimit))
        return (retained, archived)
    }

    /// Audits working memory contexts against bloat and multi-turn leaks.
    public static func auditWorkingMemory(
        contexts: [UUID: String],
        policy: MemoryCompactionPolicy
    ) -> [MemoryIntegrityViolation] {
        var violations: [MemoryIntegrityViolation] = []

        for (botId, text) in contexts {
            let byteCount = text.utf8.count
            if byteCount > policy.maxWorkingContextBytes {
                violations.append(
                    MemoryIntegrityViolation(
                        botId: botId.uuidString,
                        ruleId: "working_memory_bloat",
                        severity: .high,
                        message: "Working memory context (\(byteCount) bytes) exceeds safe threshold (\(policy.maxWorkingContextBytes) bytes).",
                        remediation: "Trigger cognitive memory compaction to synthesize working context."
                    )
                )
            }
        }
        return violations
    }

    /// Audits semantic embedding vector validity, non-zero energy, and dimensional parity.
    public static func auditVectorIntegrity(
        entry: AgentMemoryEntry,
        expectedDimensions: Int
    ) -> [MemoryIntegrityViolation] {
        var violations: [MemoryIntegrityViolation] = []
        guard let vector = CognitiveMemoryEngine.decodeEmbedding(entry.embedding) else {
            violations.append(
                MemoryIntegrityViolation(
                    botId: "entry-\(entry.id.uuidString.prefix(8))",
                    ruleId: "vector_undecodable_embedding",
                    severity: .critical,
                    message: "Memory entry embedding data cannot be decoded into floating-point vector.",
                    remediation: "Regenerate embedding using nomic-embed-text or deterministic hash fallback."
                )
            )
            return violations
        }

        if vector.count != expectedDimensions {
            violations.append(
                MemoryIntegrityViolation(
                    botId: "entry-\(entry.id.uuidString.prefix(8))",
                    ruleId: "vector_dimension_mismatch",
                    severity: .high,
                    message: "Vector dimension (\(vector.count)) does not match expected model dimension (\(expectedDimensions)).",
                    remediation: "Re-index embeddings with uniform dimensional alignment."
                )
            )
        }

        let magnitude = sqrt(vector.reduce(0.0) { $0 + $1 * $1 })
        if magnitude.isZero || magnitude.isNaN {
            violations.append(
                MemoryIntegrityViolation(
                    botId: "entry-\(entry.id.uuidString.prefix(8))",
                    ruleId: "vector_zero_magnitude",
                    severity: .critical,
                    message: "Vector magnitude is zero or NaN; cosine similarity calculations will fail.",
                    remediation: "Filter out empty token inputs or normalize vector."
                )
            )
        }

        return violations
    }

    /// Evaluates a full bot cognitive memory dataset.
    public static func auditBotMemory(
        botId: UUID,
        workingContext: String,
        episodes: [CognitiveMemoryEngine.EpisodicEntry],
        memoryEntries: [AgentMemoryEntry],
        policy: MemoryCompactionPolicy = MemoryCompactionPolicy()
    ) -> (violations: [MemoryIntegrityViolation], compaction: MemoryCompactionResult) {
        var violations: [MemoryIntegrityViolation] = []

        // Working memory check
        violations.append(contentsOf: auditWorkingMemory(contexts: [botId: workingContext], policy: policy))

        // Episodic validation
        for ep in episodes {
            if !ep.isWellFormed {
                violations.append(
                    MemoryIntegrityViolation(
                        botId: botId.uuidString,
                        ruleId: "malformed_episodic_entry",
                        severity: .high,
                        message: "Episodic entry id '\(ep.id)' has empty eventType or summary.",
                        remediation: "Ensure all episodic events record a structured event type and non-blank summary."
                    )
                )
            }
        }

        // Compaction simulation
        let preCount = episodes.count
        let preBytes = episodes.reduce(0) { $0 + $1.summary.utf8.count }
        let (retained, archived) = compactEpisodes(episodes, maxLimit: policy.archiveThreshold)
        let postBytes = retained.reduce(0) { $0 + $1.summary.utf8.count }

        let compaction = MemoryCompactionResult(
            botId: botId.uuidString,
            preCompactionEntries: preCount,
            postCompactionEntries: retained.count,
            archivedEntries: archived.count,
            preCompactionBytes: preBytes,
            postCompactionBytes: postBytes
        )

        if episodes.count > policy.maxEpisodicEntriesPerBot {
            violations.append(
                MemoryIntegrityViolation(
                    botId: botId.uuidString,
                    ruleId: "episodic_over_capacity",
                    severity: .medium,
                    message: "Episodic memory count (\(episodes.count)) exceeds maximum active capacity (\(policy.maxEpisodicEntriesPerBot)).",
                    remediation: "Archive older episodes into cold storage tier."
                )
            )
        }

        // Vector integrity
        for entry in memoryEntries {
            violations.append(contentsOf: auditVectorIntegrity(entry: entry, expectedDimensions: policy.minEmbeddingDimensions))
        }

        return (violations, compaction)
    }

    /// Evaluates a collection of bots and produces a comprehensive report.
    public static func audit(
        bots: [(botId: UUID, workingContext: String, episodes: [CognitiveMemoryEngine.EpisodicEntry], memoryEntries: [AgentMemoryEntry])],
        policy: MemoryCompactionPolicy = MemoryCompactionPolicy()
    ) -> MemoryCompactionAuditReport {
        var allViolations: [MemoryIntegrityViolation] = []
        var allCompactions: [MemoryCompactionResult] = []
        var recommendations: [String] = []

        for bot in bots {
            let (violations, compaction) = auditBotMemory(
                botId: bot.botId,
                workingContext: bot.workingContext,
                episodes: bot.episodes,
                memoryEntries: bot.memoryEntries,
                policy: policy
            )
            allViolations.append(contentsOf: violations)
            allCompactions.append(compaction)
        }

        var deduction = 0.0
        for v in allViolations {
            switch v.severity {
            case .critical: deduction += 35.0
            case .high: deduction += 20.0
            case .medium: deduction += 10.0
            case .low: deduction += 5.0
            case .info: deduction += 1.0
            }
        }

        let finalScore = max(0.0, 100.0 - deduction)
        let hasCriticalOrHigh = allViolations.contains(where: { $0.severity == .critical || $0.severity == .high })
        let passed = finalScore >= 70.0 && !hasCriticalOrHigh

        if !allViolations.isEmpty {
            recommendations.append("Enforce working memory flushing between discrete agent task loops.")
            recommendations.append("Run automatic episodic compaction when episode logs exceed 500 records.")
            recommendations.append("Validate vector embeddings for non-zero L2 norms prior to insertion in vector store.")
        } else {
            recommendations.append("Cognitive memory stores and semantic vectors comply with integrity baselines.")
        }

        return MemoryCompactionAuditReport(
            passed: passed,
            score: finalScore,
            evaluatedBots: bots.count,
            violations: allViolations,
            compactionSummaries: allCompactions,
            recommendations: recommendations
        )
    }
}
