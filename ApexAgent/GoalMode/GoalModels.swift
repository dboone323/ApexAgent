import Foundation

// MARK: - Goal Mode Models (Issue #79)

/// Status of an individual success criterion.
public enum GoalCriterionStatus: String, Codable, Sendable, CaseIterable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case blocked = "blocked"

    public var badge: String {
        switch self {
        case .pending: return "⏳ Pending"
        case .inProgress: return "🔄 In Progress"
        case .completed: return "✅ Completed"
        case .blocked: return "⛔️ Blocked"
        }
    }
}

/// An individual, checkable success criterion for a goal.
public struct GoalSuccessCriterion: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var description: String
    public var status: GoalCriterionStatus
    public var notes: String?
    public var completedAt: Date?
    public var blockedReason: String?

    public init(
        id: String,
        description: String,
        status: GoalCriterionStatus = .pending,
        notes: String? = nil,
        completedAt: Date? = nil,
        blockedReason: String? = nil
    ) {
        self.id = id
        self.description = description
        self.status = status
        self.notes = notes
        self.completedAt = completedAt
        self.blockedReason = blockedReason
    }
}

/// Overall status of a Goal.
public enum GoalStatus: String, Codable, Sendable, CaseIterable {
    case active = "active"
    case inProgress = "in_progress"
    case completed = "completed"
    case blocked = "blocked"
    case paused = "paused"
    case failed = "failed"
}

/// Overall progress assessment.
public enum GoalOverallProgress: String, Codable, Sendable, CaseIterable {
    case done = "done"
    case inProgress = "in_progress"
    case blocked = "blocked"
    case pending = "pending"
}

/// Honest, checkable report of progress against success criteria.
public struct GoalProgressReport: Codable, Sendable, Equatable {
    public let overallStatus: GoalOverallProgress
    public let totalCriteria: Int
    public let completedCriteria: Int
    public let blockedCriteria: Int
    public let inProgressCriteria: Int
    public let pendingCriteria: Int
    public let criteriaStatuses: [String: GoalCriterionStatus]
    public let summary: String
    public let activeBlockers: [String]

    public init(
        overallStatus: GoalOverallProgress,
        totalCriteria: Int,
        completedCriteria: Int,
        blockedCriteria: Int,
        inProgressCriteria: Int,
        pendingCriteria: Int,
        criteriaStatuses: [String: GoalCriterionStatus],
        summary: String,
        activeBlockers: [String] = []
    ) {
        self.overallStatus = overallStatus
        self.totalCriteria = totalCriteria
        self.completedCriteria = completedCriteria
        self.blockedCriteria = blockedCriteria
        self.inProgressCriteria = inProgressCriteria
        self.pendingCriteria = pendingCriteria
        self.criteriaStatuses = criteriaStatuses
        self.summary = summary
        self.activeBlockers = activeBlockers
    }
}

/// A persistent objective the agent re-plans against over hours/days.
public struct Goal: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var objective: String
    public var successCriteria: [GoalSuccessCriterion]
    public var status: GoalStatus
    public let createdAt: Date
    public var updatedAt: Date
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        title: String,
        objective: String,
        successCriteria: [GoalSuccessCriterion],
        status: GoalStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.objective = objective
        self.successCriteria = successCriteria
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }

    /// Evaluates progress against success criteria strictly and honestly.
    public func reportProgress() -> GoalProgressReport {
        let total = successCriteria.count
        guard total > 0 else {
            return GoalProgressReport(
                overallStatus: .done,
                totalCriteria: 0,
                completedCriteria: 0,
                blockedCriteria: 0,
                inProgressCriteria: 0,
                pendingCriteria: 0,
                criteriaStatuses: [:],
                summary: "Goal has no criteria defined."
            )
        }

        let completed = successCriteria.filter { $0.status == .completed }.count
        let blocked = successCriteria.filter { $0.status == .blocked }.count
        let inProg = successCriteria.filter { $0.status == .inProgress }.count
        let pending = successCriteria.filter { $0.status == .pending }.count

        var statuses: [String: GoalCriterionStatus] = [:]
        for c in successCriteria {
            statuses[c.id] = c.status
        }

        let blockers = successCriteria.compactMap { c -> String? in
            guard c.status == .blocked else { return nil }
            return "[\(c.id)] \(c.description): \(c.blockedReason ?? c.notes ?? "Blocked")"
        }

        let overall: GoalOverallProgress
        let summary: String

        if completed == total {
            overall = .done
            summary = "All \(total)/\(total) success criteria met. Goal is complete."
        } else if blocked > 0 {
            // Blocked stays blocked!
            overall = .blocked
            summary = "\(completed)/\(total) criteria met. \(blocked) criteria blocked by setbacks: \(blockers.joined(separator: "; "))"
        } else if inProg > 0 || completed > 0 {
            overall = .inProgress
            summary = "\(completed)/\(total) criteria completed, \(inProg) in progress, \(pending) pending."
        } else {
            overall = .pending
            summary = "All \(total) criteria pending."
        }

        return GoalProgressReport(
            overallStatus: overall,
            totalCriteria: total,
            completedCriteria: completed,
            blockedCriteria: blocked,
            inProgressCriteria: inProg,
            pendingCriteria: pending,
            criteriaStatuses: statuses,
            summary: summary,
            activeBlockers: blockers
        )
    }

    /// Returns whether this goal is complete.
    /// Strictly true ONLY if all criteria are completed.
    public var isComplete: Bool {
        guard !successCriteria.isEmpty else { return false }
        return successCriteria.allSatisfy { $0.status == .completed }
    }

    /// Formats the goal into human-readable Markdown for files-first memory tier storage.
    public func formatMarkdown() -> String {
        var lines: [String] = []
        lines.append("# Goal: \(title)")
        lines.append("")
        lines.append("- **ID:** `\(id.uuidString)`")
        lines.append("- **Status:** \(status.rawValue)")
        lines.append("- **Created:** \(ISO8601DateFormatter().string(from: createdAt))")
        lines.append("- **Updated:** \(ISO8601DateFormatter().string(from: updatedAt))")
        lines.append("")
        lines.append("## Objective")
        lines.append(objective)
        lines.append("")
        lines.append("## Success Criteria")
        for c in successCriteria {
            let mark: String
            switch c.status {
            case .completed: mark = "[x]"
            case .blocked: mark = "[!]"
            case .inProgress: mark = "[-]"
            case .pending: mark = "[ ]"
            }
            var line = "- \(mark) (\(c.id)) \(c.description)"
            if let reason = c.blockedReason {
                line += " <!-- blocked: \(reason) -->"
            } else if let notes = c.notes {
                line += " <!-- note: \(notes) -->"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Goal Ledger Entry Kind

public enum GoalLedgerEntryKind: String, Codable, Sendable, CaseIterable {
    case plan = "plan"
    case step = "step"
    case setback = "setback"

    public var tag: String {
        switch self {
        case .plan: return "[PLAN]"
        case .step: return "[STEP]"
        case .setback: return "[SETBACK]"
        }
    }
}

// MARK: - Goal Ledger Entry

/// A single immutable entry in the append-only progress ledger.
public struct GoalLedgerEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let goalId: UUID
    public let sequenceNumber: Int
    public let timestamp: Date
    public let kind: GoalLedgerEntryKind
    public let text: String
    public let stepId: String?
    public let criterionId: String?
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        goalId: UUID,
        sequenceNumber: Int,
        timestamp: Date = Date(),
        kind: GoalLedgerEntryKind,
        text: String,
        stepId: String? = nil,
        criterionId: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.goalId = goalId
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.kind = kind
        self.text = text
        self.stepId = stepId
        self.criterionId = criterionId
        self.metadata = metadata
    }

    public func formatMarkdownLine() -> String {
        let ts = ISO8601DateFormatter().string(from: timestamp)
        var line = "- `\(ts)` #\(sequenceNumber) **\(kind.tag)** \(text)"
        if let stepId = stepId {
            line += " (step: \(stepId))"
        }
        if let criterionId = criterionId {
            line += " (criterion: \(criterionId))"
        }
        return line
    }
}

// MARK: - Goal Plan Models

/// A planned step in an updated goal plan.
public struct GoalPlanStep: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let criterionId: String?
    public let rationale: String
    public let avoidSetbacks: [String]
    public var status: String

    public init(
        id: String,
        title: String,
        criterionId: String? = nil,
        rationale: String,
        avoidSetbacks: [String] = [],
        status: String = "pending"
    ) {
        self.id = id
        self.title = title
        self.criterionId = criterionId
        self.rationale = rationale
        self.avoidSetbacks = avoidSetbacks
        self.status = status
    }
}

/// An updated plan produced by re-planning against the goal and progress ledger.
public struct GoalPlan: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let goalId: UUID
    public let generatedAt: Date
    public let steps: [GoalPlanStep]
    public let activeBlockers: [String]
    public let summary: String

    public init(
        id: UUID = UUID(),
        goalId: UUID,
        generatedAt: Date = Date(),
        steps: [GoalPlanStep],
        activeBlockers: [String] = [],
        summary: String
    ) {
        self.id = id
        self.goalId = goalId
        self.generatedAt = generatedAt
        self.steps = steps
        self.activeBlockers = activeBlockers
        self.summary = summary
    }
}
