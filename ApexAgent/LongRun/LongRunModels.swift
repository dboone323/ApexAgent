import Foundation

// MARK: - Long Run Models & Serialization (Issue #77)

/// Status of an active or historical long run.
public enum LongRunStatus: Codable, Sendable, Equatable {
    case queued
    case running
    case paused
    case interrupted(reason: String)
    case completed
    case failed(reason: String)
    case budgetExceeded(type: LongRunBudgetType, limit: Double, actual: Double)

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case budgetType
        case limit
        case actual
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "queued":
            self = .queued
        case "running":
            self = .running
        case "paused":
            self = .paused
        case "interrupted":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .interrupted(reason: reason)
        case "completed":
            self = .completed
        case "failed":
            let reason = try container.decode(String.self, forKey: .reason)
            self = .failed(reason: reason)
        case "budgetExceeded":
            let budgetType = try container.decode(LongRunBudgetType.self, forKey: .budgetType)
            let limit = try container.decode(Double.self, forKey: .limit)
            let actual = try container.decode(Double.self, forKey: .actual)
            self = .budgetExceeded(type: budgetType, limit: limit, actual: actual)
        default:
            self = .failed(reason: "Unknown status kind: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:
            try container.encode("queued", forKey: .kind)
        case .running:
            try container.encode("running", forKey: .kind)
        case .paused:
            try container.encode("paused", forKey: .kind)
        case .interrupted(let reason):
            try container.encode("interrupted", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .completed:
            try container.encode("completed", forKey: .kind)
        case .failed(let reason):
            try container.encode("failed", forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case .budgetExceeded(let type, let limit, let actual):
            try container.encode("budgetExceeded", forKey: .kind)
            try container.encode(type, forKey: .budgetType)
            try container.encode(limit, forKey: .limit)
            try container.encode(actual, forKey: .actual)
        }
    }

    public var badge: String {
        switch self {
        case .queued:
            return "⏳ Queued"
        case .running:
            return "⚡️ Running"
        case .paused:
            return "⏸️ Paused"
        case .interrupted(let reason):
            return "🛑 Interrupted (\(reason))"
        case .completed:
            return "✅ Completed"
        case .failed(let reason):
            return "❌ Failed: \(reason)"
        case .budgetExceeded(let type, let limit, let actual):
            return "⛔️ Budget Exceeded [\(type.rawValue): \(actual)/\(limit)]"
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .budgetExceeded:
            return true
        case .queued, .running, .paused, .interrupted:
            return false
        }
    }

    public var isResumable: Bool {
        switch self {
        case .paused, .interrupted:
            return true
        case .queued, .running, .completed, .failed, .budgetExceeded:
            return false
        }
    }
}

/// Category of run budget enforced by the coordinator.
public enum LongRunBudgetType: String, Codable, Sendable, Equatable {
    case time
    case tokens
    case steps
}

/// Budget constraints assigned to a run.
public struct LongRunBudgetPolicy: Codable, Sendable, Equatable {
    public var maxWallClockSeconds: TimeInterval?
    public var maxTokens: Int?
    public var maxSteps: Int?

    public init(
        maxWallClockSeconds: TimeInterval? = nil,
        maxTokens: Int? = nil,
        maxSteps: Int? = nil
    ) {
        self.maxWallClockSeconds = maxWallClockSeconds
        self.maxTokens = maxTokens
        self.maxSteps = maxSteps
    }

    public static let unlimited = LongRunBudgetPolicy()
}

/// Accumulated usage tracking across time, tokens, and steps.
public struct LongRunBudgetUsage: Codable, Sendable, Equatable {
    public var elapsedWallClockSeconds: TimeInterval
    public var tokensConsumed: Int
    public var stepsExecuted: Int

    public init(
        elapsedWallClockSeconds: TimeInterval = 0,
        tokensConsumed: Int = 0,
        stepsExecuted: Int = 0
    ) {
        self.elapsedWallClockSeconds = elapsedWallClockSeconds
        self.tokensConsumed = tokensConsumed
        self.stepsExecuted = stepsExecuted
    }

    /// Evaluates if any configured budget constraint is exceeded.
    public func evaluateExceeded(policy: LongRunBudgetPolicy) -> (type: LongRunBudgetType, limit: Double, actual: Double)? {
        if let maxTime = policy.maxWallClockSeconds, elapsedWallClockSeconds >= maxTime {
            return (.time, maxTime, elapsedWallClockSeconds)
        }
        if let maxTokens = policy.maxTokens, tokensConsumed >= maxTokens {
            return (.tokens, Double(maxTokens), Double(tokensConsumed))
        }
        if let maxSteps = policy.maxSteps, stepsExecuted >= maxSteps {
            return (.steps, Double(maxSteps), Double(stepsExecuted))
        }
        return nil
    }
}

/// Policy for retrying failed steps with exponential backoff.
public struct LongRunRetryPolicy: Codable, Sendable, Equatable {
    public var maxRetries: Int
    public var initialBackoffSeconds: TimeInterval
    public var backoffMultiplier: Double
    public var maxBackoffSeconds: TimeInterval

    public init(
        maxRetries: Int = 3,
        initialBackoffSeconds: TimeInterval = 0.5,
        backoffMultiplier: Double = 2.0,
        maxBackoffSeconds: TimeInterval = 10.0
    ) {
        self.maxRetries = max(0, maxRetries)
        self.initialBackoffSeconds = max(0.01, initialBackoffSeconds)
        self.backoffMultiplier = max(1.0, backoffMultiplier)
        self.maxBackoffSeconds = max(self.initialBackoffSeconds, maxBackoffSeconds)
    }

    public static let `default` = LongRunRetryPolicy()

    public static let none = LongRunRetryPolicy(
        maxRetries: 0,
        initialBackoffSeconds: 0.01,
        backoffMultiplier: 1.0,
        maxBackoffSeconds: 0.01
    )

    /// Computes backoff delay for the given attempt (1-based index).
    public func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let factor = pow(backoffMultiplier, Double(attempt - 1))
        let calculated = initialBackoffSeconds * factor
        return min(calculated, maxBackoffSeconds)
    }
}

/// Classification of steps that can be run inside a long run.
public enum LongRunStepKind: String, Codable, Sendable, Equatable {
    case shellCommand
    case fileWrite
    case fileVerify
    case tokenProcessing
    case sleepDelay
    case deterministicFailThenSucceed
}

/// Declarative specification of one step in a long run.
public struct LongRunStepSpec: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let kind: LongRunStepKind
    public let inputPayload: [String: String]
    public let estimatedTokens: Int

    public init(
        id: String,
        title: String,
        kind: LongRunStepKind,
        inputPayload: [String: String] = [:],
        estimatedTokens: Int = 0
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.inputPayload = inputPayload
        self.estimatedTokens = estimatedTokens
    }
}

/// Execution lifecycle status of a single step.
public enum StepExecutionStatus: String, Codable, Sendable, Equatable {
    case pending
    case running
    case retrying
    case completed
    case failed
}

/// Durable audit record for a single step execution.
public struct LongRunStepRecord: Identifiable, Codable, Sendable, Equatable {
    public var id: String { stepId }
    public let stepId: String
    public let title: String
    public var status: StepExecutionStatus
    public var attempts: Int
    public var output: String?
    public var error: String?
    public var tokensUsed: Int
    public var startedAt: Date?
    public var finishedAt: Date?
    public var retryDelays: [TimeInterval]

    public init(
        stepId: String,
        title: String,
        status: StepExecutionStatus = .pending,
        attempts: Int = 0,
        output: String? = nil,
        error: String? = nil,
        tokensUsed: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        retryDelays: [TimeInterval] = []
    ) {
        self.stepId = stepId
        self.title = title
        self.status = status
        self.attempts = attempts
        self.output = output
        self.error = error
        self.tokensUsed = tokensUsed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.retryDelays = retryDelays
    }
}

/// Static definition of an entire long run.
public struct LongRunSpec: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let descriptionText: String
    public let steps: [LongRunStepSpec]
    public let budgetPolicy: LongRunBudgetPolicy
    public let retryPolicy: LongRunRetryPolicy
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        descriptionText: String = "",
        steps: [LongRunStepSpec],
        budgetPolicy: LongRunBudgetPolicy = .unlimited,
        retryPolicy: LongRunRetryPolicy = .default,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.descriptionText = descriptionText
        self.steps = steps
        self.budgetPolicy = budgetPolicy
        self.retryPolicy = retryPolicy
        self.createdAt = createdAt
    }
}

/// Structured log entry captured during run progression.
public struct LongRunLogEntry: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let stepId: String?
    public let message: String
    public let level: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        stepId: String? = nil,
        message: String,
        level: String = "INFO"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.stepId = stepId
        self.message = message
        self.level = level
    }
}

/// Durable checkpoint capturing complete state of a long run at a specific moment.
public struct LongRunCheckpoint: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID { runId }
    public let runId: UUID
    public let spec: LongRunSpec
    public var sequenceNumber: Int
    public var status: LongRunStatus
    public var currentStepIndex: Int
    public var completedStepIds: [String]
    public var stepRecords: [LongRunStepRecord]
    public var sharedState: [String: String]
    public var budgetUsage: LongRunBudgetUsage
    public var savedAt: Date
    public var processId: Int32
    public var logs: [LongRunLogEntry]

    public init(
        runId: UUID,
        spec: LongRunSpec,
        sequenceNumber: Int = 0,
        status: LongRunStatus = .queued,
        currentStepIndex: Int = 0,
        completedStepIds: [String] = [],
        stepRecords: [LongRunStepRecord]? = nil,
        sharedState: [String: String] = [:],
        budgetUsage: LongRunBudgetUsage = LongRunBudgetUsage(),
        savedAt: Date = Date(),
        processId: Int32 = ProcessInfo.processInfo.processIdentifier,
        logs: [LongRunLogEntry] = []
    ) {
        self.runId = runId
        self.spec = spec
        self.sequenceNumber = sequenceNumber
        self.status = status
        self.currentStepIndex = currentStepIndex
        self.completedStepIds = completedStepIds
        self.stepRecords = stepRecords ?? spec.steps.map {
            LongRunStepRecord(stepId: $0.id, title: $0.title)
        }
        self.sharedState = sharedState
        self.budgetUsage = budgetUsage
        self.savedAt = savedAt
        self.processId = processId
        self.logs = logs
    }

    /// Progress percentage from 0.0 to 1.0.
    public var progressFraction: Double {
        guard !spec.steps.isEmpty else { return 1.0 }
        return Double(completedStepIds.count) / Double(spec.steps.count)
    }

    /// Whether this checkpoint's status allows resumption.
    public var isResumable: Bool {
        status.isResumable
    }

    public func formatMarkdownReceipt() -> String {
        var md = "# 📋 Long Run Receipt: `\(spec.name)`\n\n"
        md += "| Property | Value |\n"
        md += "|---|---|\n"
        md += "| Run ID | `\(runId.uuidString)` |\n"
        md += "| Status | \(status.badge) |\n"
        md += "| Checkpoint Seq | `\(sequenceNumber)` |\n"
        md += "| Progress | `\(completedStepIds.count)/\(spec.steps.count)` (\(Int(progressFraction * 100))%) |\n"
        md += "| Elapsed Time | `\(String(format: "%.2f", budgetUsage.elapsedWallClockSeconds))s` |\n"
        md += "| Tokens Used | `\(budgetUsage.tokensConsumed)` |\n"
        md += "| Steps Executed | `\(budgetUsage.stepsExecuted)` |\n"
        md += "| Saved At | `\(savedAt)` |\n"
        md += "| Process ID | `\(processId)` |\n\n"

        md += "## Step Execution Summary\n\n"
        md += "| Step ID | Title | Status | Attempts | Tokens | Duration |\n"
        md += "|---|---|---|---|---|---|\n"
        for rec in stepRecords {
            let durStr: String
            if let start = rec.startedAt, let finish = rec.finishedAt {
                durStr = String(format: "%.2fs", finish.timeIntervalSince(start))
            } else {
                durStr = "-"
            }
            md += "| `\(rec.stepId)` | \(rec.title) | \(rec.status.rawValue) | \(rec.attempts) | \(rec.tokensUsed) | \(durStr) |\n"
        }
        return md
    }
}
