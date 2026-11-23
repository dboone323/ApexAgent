import Foundation
import SharedKit

// MARK: - Goal Mode Service (Issue #79)

/// Service responsible for persistent goals and an append-only progress ledger.
/// Reuses files-first memory tiers (#80/#82) and checkpointing concepts (#77).
public actor GoalModeService {
    public let workspaceURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public private(set) var activeGoal: Goal?
    public private(set) var cachedLedger: [GoalLedgerEntry] = []

    public init(workspaceURL: URL? = nil) {
        if let workspaceURL {
            self.workspaceURL = workspaceURL
        } else {
            let defaultPath = ApexAgentStoragePaths.directory("spaces/default/workspace").path
            self.workspaceURL = URL(fileURLWithPath: defaultPath, isDirectory: true)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc

        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - Path Resolution (Files-First Memory Tiers)

    public nonisolated var goalsDirectory: URL {
        workspaceURL.appendingPathComponent("goals", isDirectory: true)
    }

    public nonisolated var activeGoalPointerURL: URL {
        goalsDirectory.appendingPathComponent("active_goal_id.txt")
    }

    public nonisolated func goalDirectory(for goalId: UUID) -> URL {
        goalsDirectory.appendingPathComponent(goalId.uuidString, isDirectory: true)
    }

    public nonisolated func goalFileURL(for goalId: UUID) -> URL {
        goalDirectory(for: goalId).appendingPathComponent("goal.json")
    }

    public nonisolated func goalMarkdownURL(for goalId: UUID) -> URL {
        goalDirectory(for: goalId).appendingPathComponent("GOAL.md")
    }

    public nonisolated func ledgerJSONLURL(for goalId: UUID) -> URL {
        goalDirectory(for: goalId).appendingPathComponent("ledger.jsonl")
    }

    public nonisolated func ledgerMarkdownURL(for goalId: UUID) -> URL {
        goalDirectory(for: goalId).appendingPathComponent("LEDGER.md")
    }

    public nonisolated func latestPlanURL(for goalId: UUID) -> URL {
        goalDirectory(for: goalId).appendingPathComponent("latest_plan.json")
    }

    // MARK: - Goal Lifecycle

    /// Creates a new Goal, persists it to the files-first memory tier, and initializes the ledger.
    @discardableResult
    public func createGoal(
        title: String,
        objective: String,
        criteria: [String],
        metadata: [String: String] = [:]
    ) throws -> Goal {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedObjective = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw NSError(domain: "GoalModeService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Goal title cannot be empty."])
        }
        guard !trimmedObjective.isEmpty else {
            throw NSError(domain: "GoalModeService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Goal objective cannot be empty."])
        }

        var successCriteria: [GoalSuccessCriterion] = []
        for (idx, c) in criteria.enumerated() {
            let cTrimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cTrimmed.isEmpty else { continue }
            successCriteria.append(GoalSuccessCriterion(
                id: "c\(idx + 1)",
                description: cTrimmed,
                status: .pending
            ))
        }

        let newGoal = Goal(
            title: trimmedTitle,
            objective: trimmedObjective,
            successCriteria: successCriteria,
            status: .active,
            createdAt: Date(),
            updatedAt: Date(),
            metadata: metadata
        )

        self.activeGoal = newGoal
        self.cachedLedger = []

        let dir = goalDirectory(for: newGoal.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Set as active goal
        try newGoal.id.uuidString.write(to: activeGoalPointerURL, atomically: true, encoding: .utf8)

        // Save Goal model and markdown
        try persistGoal(newGoal)

        // Initial ledger entry (plan)
        _ = try appendLedgerEntry(
            kind: .plan,
            text: "Goal initialized: '\(trimmedTitle)' with \(successCriteria.count) success criteria.",
            metadata: ["event": "goal_created"]
        )

        RunTraceManager.shared.recordMemoryWrite(
            tier: "goal",
            path: goalFileURL(for: newGoal.id).path,
            bytesWritten: 100,
            detail: "Created new persistent goal '\(trimmedTitle)'"
        )

        return newGoal
    }

    /// Loads the currently active goal from disk if one exists.
    @discardableResult
    public func loadActiveGoal() throws -> Goal? {
        guard FileManager.default.fileExists(atPath: activeGoalPointerURL.path),
              let idStr = try? String(contentsOf: activeGoalPointerURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let goalId = UUID(uuidString: idStr) else {
            return nil
        }
        return try loadGoal(id: goalId)
    }

    /// Loads a specific Goal by UUID, reconstructing the ledger and plan.
    @discardableResult
    public func loadGoal(id: UUID) throws -> Goal? {
        let jsonURL = goalFileURL(for: id)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: jsonURL)
        let loadedGoal = try decoder.decode(Goal.self, from: data)
        self.activeGoal = loadedGoal

        // Reconstruct ledger from disk
        self.cachedLedger = try loadLedgerFromDisk(for: id)

        RunTraceManager.shared.recordMemoryRead(
            tier: "goal",
            path: jsonURL.path,
            detail: "Loaded persistent goal '\(loadedGoal.title)' with \(cachedLedger.count) ledger entries",
            bytesRead: data.count
        )

        return loadedGoal
    }

    private func persistGoal(_ goal: Goal) throws {
        let dir = goalDirectory(for: goal.id)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // 1. Write machine-readable JSON
        let data = try encoder.encode(goal)
        try data.write(to: goalFileURL(for: goal.id), options: .atomic)

        // 2. Write human-readable Markdown (files-first tier)
        let md = goal.formatMarkdown()
        try md.write(to: goalMarkdownURL(for: goal.id), atomically: true, encoding: .utf8)
    }

    // MARK: - Append-Only Progress Ledger

    /// Appends a new immutable entry to the ledger.
    /// The ledger is NEVER rewritten or overwritten — new entries only.
    @discardableResult
    public func appendLedgerEntry(
        kind: GoalLedgerEntryKind,
        text: String,
        stepId: String? = nil,
        criterionId: String? = nil,
        metadata: [String: String] = [:]
    ) throws -> GoalLedgerEntry {
        guard let goal = activeGoal else {
            throw NSError(domain: "GoalModeService", code: 3, userInfo: [NSLocalizedDescriptionKey: "No active goal set."])
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let seq = cachedLedger.count + 1
        let entry = GoalLedgerEntry(
            goalId: goal.id,
            sequenceNumber: seq,
            timestamp: Date(),
            kind: kind,
            text: trimmedText,
            stepId: stepId,
            criterionId: criterionId,
            metadata: metadata
        )

        // Append to in-memory state
        cachedLedger.append(entry)

        // Append to disk (JSONL)
        let jsonlURL = ledgerJSONLURL(for: goal.id)
        let entryData = try encoder.encode(entry)
        guard var entryString = String(data: entryData, encoding: .utf8) else {
            throw NSError(domain: "GoalModeService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to encode ledger entry string."])
        }
        // Normalize to single line for jsonl
        entryString = entryString.replacingOccurrences(of: "\n", with: " ") + "\n"

        if let fileHandle = try? FileHandle(forWritingTo: jsonlURL) {
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            if let d = entryString.data(using: .utf8) {
                fileHandle.write(d)
            }
        } else {
            try entryString.write(to: jsonlURL, atomically: true, encoding: .utf8)
        }

        // Append to disk (Markdown)
        let mdURL = ledgerMarkdownURL(for: goal.id)
        let mdLine = entry.formatMarkdownLine() + "\n"
        if let fileHandle = try? FileHandle(forWritingTo: mdURL) {
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            if let d = mdLine.data(using: .utf8) {
                fileHandle.write(d)
            }
        } else {
            let header = "# Goal Progress Ledger: \(goal.title)\n\n"
            try (header + mdLine).write(to: mdURL, atomically: true, encoding: .utf8)
        }

        RunTraceManager.shared.recordMemoryWrite(
            tier: "goal_ledger",
            path: jsonlURL.path,
            bytesWritten: entryString.utf8.count,
            detail: "Appended ledger entry #\(seq) [\(kind.rawValue)]: \(trimmedText.prefix(50))"
        )

        return entry
    }

    /// Returns the full list of ledger entries.
    public func getLedger() -> [GoalLedgerEntry] {
        return cachedLedger
    }

    private func loadLedgerFromDisk(for goalId: UUID) throws -> [GoalLedgerEntry] {
        let jsonlURL = ledgerJSONLURL(for: goalId)
        guard FileManager.default.fileExists(atPath: jsonlURL.path),
              let content = try? String(contentsOf: jsonlURL, encoding: .utf8) else {
            return []
        }

        var entries: [GoalLedgerEntry] = []
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let d = trimmed.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(GoalLedgerEntry.self, from: d) {
                entries.append(entry)
            }
        }
        return entries
    }

    // MARK: - Success Criteria Management

    /// Updates the status of an individual success criterion.
    @discardableResult
    public func updateCriterionStatus(
        criterionId: String,
        status: GoalCriterionStatus,
        notes: String? = nil,
        blockedReason: String? = nil
    ) throws -> Goal {
        guard var goal = activeGoal else {
            throw NSError(domain: "GoalModeService", code: 5, userInfo: [NSLocalizedDescriptionKey: "No active goal set."])
        }

        guard let idx = goal.successCriteria.firstIndex(where: { $0.id == criterionId }) else {
            throw NSError(domain: "GoalModeService", code: 6, userInfo: [NSLocalizedDescriptionKey: "Criterion '\(criterionId)' not found."])
        }

        goal.successCriteria[idx].status = status
        if let notes {
            goal.successCriteria[idx].notes = notes
        }
        if status == .completed {
            goal.successCriteria[idx].completedAt = Date()
            goal.successCriteria[idx].blockedReason = nil
        } else if status == .blocked {
            goal.successCriteria[idx].blockedReason = blockedReason ?? notes ?? "Setback blocked criterion."
        }
        goal.updatedAt = Date()

        // Sync active goal
        self.activeGoal = goal
        try persistGoal(goal)

        let ledgerKind: GoalLedgerEntryKind = status == .blocked ? .setback : .step
        _ = try appendLedgerEntry(
            kind: ledgerKind,
            text: "Criterion '\(criterionId)' (\(goal.successCriteria[idx].description)) updated to \(status.rawValue): \(notes ?? blockedReason ?? "")",
            criterionId: criterionId,
            metadata: ["status": status.rawValue]
        )

        return goal
    }

    // MARK: - Re-plan Operation Against Setbacks

    /// Generates an updated plan by reading the goal and the full progress ledger.
    /// The re-plan NEVER ignores recorded setbacks and avoids repeating failed steps.
    public func replan() throws -> GoalPlan {
        guard var goal = activeGoal else {
            throw NSError(domain: "GoalModeService", code: 7, userInfo: [NSLocalizedDescriptionKey: "No active goal to replan."])
        }

        // 1. Read all setbacks recorded in the ledger
        let setbacks = cachedLedger.filter { $0.kind == .setback }

        // Map setbacks by criterionId and text
        var setbacksByCriterion: [String: [GoalLedgerEntry]] = [:]
        for sb in setbacks {
            if let cid = sb.criterionId {
                setbacksByCriterion[cid, default: []].append(sb)
            }
        }

        var plannedSteps: [GoalPlanStep] = []
        var activeBlockers: [String] = []

        for (idx, criterion) in goal.successCriteria.enumerated() {
            let cid = criterion.id

            // Case 1: Already completed
            if criterion.status == .completed {
                continue
            }

            // Case 2: Blocked or has severe setbacks
            let relatedSetbacks = setbacksByCriterion[cid] ?? setbacks.filter {
                $0.text.localizedCaseInsensitiveContains(criterion.description) ||
                $0.text.localizedCaseInsensitiveContains(cid)
            }

            let isUnrecoverable = relatedSetbacks.contains { sb in
                let lower = sb.text.lowercased()
                return lower.contains("permission denied") ||
                       lower.contains("fatal") ||
                       lower.contains("blocked") ||
                       lower.contains("unrecoverable") ||
                       lower.contains("impossible")
            }

            if criterion.status == .blocked || isUnrecoverable {
                let blockerDesc = relatedSetbacks.last?.text ?? criterion.blockedReason ?? "Criterion blocked by setback."
                activeBlockers.append("[\(cid)] \(criterion.description): \(blockerDesc)")

                if criterion.status != .blocked {
                    goal.successCriteria[idx].status = .blocked
                    goal.successCriteria[idx].blockedReason = blockerDesc
                }
                continue
            }

            // Case 3: Criterion has recoverable setbacks — re-plan with adapted strategy
            if !relatedSetbacks.isEmpty {
                let failedApproaches = relatedSetbacks.map(\.text)
                let altStep = GoalPlanStep(
                    id: "plan-step-\(cid)-alt",
                    title: "Alternative approach for \(criterion.description)",
                    criterionId: cid,
                    rationale: "Previous approach failed due to setback: '\(relatedSetbacks.last?.text ?? "")'. Adapting strategy to avoid repeating failure.",
                    avoidSetbacks: failedApproaches,
                    status: "pending"
                )
                plannedSteps.append(altStep)
            } else {
                // Case 4: Normal pending/in-progress step
                let step = GoalPlanStep(
                    id: "plan-step-\(cid)",
                    title: "Execute \(criterion.description)",
                    criterionId: cid,
                    rationale: "Standard execution step for pending criterion.",
                    avoidSetbacks: [],
                    status: "pending"
                )
                plannedSteps.append(step)
            }
        }

        goal.updatedAt = Date()
        self.activeGoal = goal
        try persistGoal(goal)

        let summary: String
        if !activeBlockers.isEmpty {
            summary = "Re-planned \(plannedSteps.count) next steps; \(activeBlockers.count) criteria are blocked by recorded setbacks."
        } else {
            summary = "Re-planned \(plannedSteps.count) next steps based on current progress."
        }

        let plan = GoalPlan(
            goalId: goal.id,
            generatedAt: Date(),
            steps: plannedSteps,
            activeBlockers: activeBlockers,
            summary: summary
        )

        // Save latest plan to disk
        let planData = try encoder.encode(plan)
        try planData.write(to: latestPlanURL(for: goal.id), options: .atomic)

        // Record plan entry into the append-only ledger
        _ = try appendLedgerEntry(
            kind: .plan,
            text: "Re-plan generated: \(summary)",
            metadata: [
                "stepCount": "\(plannedSteps.count)",
                "blockerCount": "\(activeBlockers.count)",
                "setbackCount": "\(setbacks.count)"
            ]
        )

        return plan
    }

    // MARK: - Progress & Completion

    /// Reports current progress against success criteria honestly.
    public func reportProgress() -> GoalProgressReport {
        guard let goal = activeGoal else {
            return GoalProgressReport(
                overallStatus: .pending,
                totalCriteria: 0,
                completedCriteria: 0,
                blockedCriteria: 0,
                inProgressCriteria: 0,
                pendingCriteria: 0,
                criteriaStatuses: [:],
                summary: "No active goal set."
            )
        }
        return goal.reportProgress()
    }

    /// Flips goal status to completed ONLY if every criterion is satisfied.
    @discardableResult
    public func completeGoalIfEligible() throws -> Bool {
        guard var goal = activeGoal else { return false }

        guard goal.isComplete else {
            return false
        }

        goal.status = .completed
        goal.updatedAt = Date()
        self.activeGoal = goal
        try persistGoal(goal)

        _ = try appendLedgerEntry(
            kind: .step,
            text: "Goal marked completed: all \(goal.successCriteria.count) success criteria verified.",
            metadata: ["event": "goal_completed"]
        )

        return true
    }
}
