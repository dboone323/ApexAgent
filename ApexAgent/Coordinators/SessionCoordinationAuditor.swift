import Foundation

// MARK: - Multi-Agent Session Coordination & Deadlock Prevention Gate (Batch 65)

/// Lifecycle status of an agent session node.
public enum AgentSessionStatus: String, Codable, Sendable {
    case active = "active"
    case waitingForApproval = "waitingForApproval"
    case waitingForSubagent = "waitingForSubagent"
    case completed = "completed"
    case cancelled = "cancelled"
    case orphaned = "orphaned"
}

/// A snapshot node representing an active or recent multi-agent session.
public struct AgentSessionNode: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let agentName: String
    public let parentSessionId: UUID?
    public let waitingOnSessionId: UUID?
    public let depth: Int
    public let messageCount: Int
    public let activeProcessesCount: Int
    public let pendingContinuationsCount: Int
    public let status: AgentSessionStatus

    public init(
        id: UUID = UUID(),
        agentName: String,
        parentSessionId: UUID? = nil,
        waitingOnSessionId: UUID? = nil,
        depth: Int = 0,
        messageCount: Int = 0,
        activeProcessesCount: Int = 0,
        pendingContinuationsCount: Int = 0,
        status: AgentSessionStatus = .active
    ) {
        self.id = id
        self.agentName = agentName
        self.parentSessionId = parentSessionId
        self.waitingOnSessionId = waitingOnSessionId
        self.depth = depth
        self.messageCount = messageCount
        self.activeProcessesCount = activeProcessesCount
        self.pendingContinuationsCount = pendingContinuationsCount
        self.status = status
    }
}

/// Violation detected in session coordination, concurrency bounds, or dependency graphs.
public struct CoordinationViolation: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(sessionId.uuidString):\(ruleId):\(message)" }
    public let sessionId: UUID
    public let ruleId: String
    public let severity: ToolSandboxSeverity
    public let message: String
    public let remediation: String

    public init(
        sessionId: UUID,
        ruleId: String,
        severity: ToolSandboxSeverity,
        message: String,
        remediation: String
    ) {
        self.sessionId = sessionId
        self.ruleId = ruleId
        self.severity = severity
        self.message = message
        self.remediation = remediation
    }
}

/// Aggregated report of multi-agent session coordination auditing.
public struct SessionCoordinationAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedSessionsCount: Int
    public let detectedDeadlocks: [[UUID]]
    public let violations: [CoordinationViolation]
    public let recommendations: [String]

    public init(
        passed: Bool,
        score: Double,
        evaluatedSessionsCount: Int,
        detectedDeadlocks: [[UUID]],
        violations: [CoordinationViolation],
        recommendations: [String]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedSessionsCount = evaluatedSessionsCount
        self.detectedDeadlocks = detectedDeadlocks
        self.violations = violations
        self.recommendations = recommendations
    }

    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

/// Autonomous gate ensuring multi-agent coordination remains deadlock-free,
/// bounded by concurrency limits, and clean of orphaned background resources.
public enum SessionCoordinationAuditor {

    public static let maxConcurrentActiveSessions: Int = 16
    public static let maxDelegationDepth: Int = 8
    public static let maxMessageTurns: Int = 100

    /// Audits a set of multi-agent session nodes.
    public static func audit(sessions: [AgentSessionNode]) -> SessionCoordinationAuditReport {
        guard !sessions.isEmpty else {
            return SessionCoordinationAuditReport(
                passed: true,
                score: 100.0,
                evaluatedSessionsCount: 0,
                detectedDeadlocks: [],
                violations: [],
                recommendations: ["No active agent sessions."]
            )
        }

        var violations: [CoordinationViolation] = []

        // Concurrency limit check
        let activeCount = sessions.filter { $0.status == .active || $0.status == .waitingForApproval || $0.status == .waitingForSubagent }.count
        if activeCount > maxConcurrentActiveSessions {
            violations.append(
                CoordinationViolation(
                    sessionId: UUID(),
                    ruleId: "COORD-001",
                    severity: .high,
                    message: "Active session count (\(activeCount)) exceeds maximum allowable concurrency limit of \(maxConcurrentActiveSessions).",
                    remediation: "Throttle multi-agent spawning or queue excess sessions."
                )
            )
        }

        // Individual session health checks
        for node in sessions {
            // Delegation depth check
            if node.depth > maxDelegationDepth {
                violations.append(
                    CoordinationViolation(
                        sessionId: node.id,
                        ruleId: "COORD-002",
                        severity: .critical,
                        message: "Session '\(node.agentName)' exceeded maximum delegation depth \(node.depth) > \(maxDelegationDepth). Possible recursive delegation.",
                        remediation: "Terminate subagent recursion and enforce shallow delegation topologies."
                    )
                )
            }

            // Message turns runaway check
            if node.messageCount > maxMessageTurns {
                violations.append(
                    CoordinationViolation(
                        sessionId: node.id,
                        ruleId: "COORD-003",
                        severity: .high,
                        message: "Session '\(node.agentName)' exceeded message turn budget (\(node.messageCount) > \(maxMessageTurns)).",
                        remediation: "Trigger cognitive compaction or terminate looping dialogue."
                    )
                )
            }

            // Orphaned resource checks
            if (node.status == .completed || node.status == .cancelled) && node.activeProcessesCount > 0 {
                violations.append(
                    CoordinationViolation(
                        sessionId: node.id,
                        ruleId: "COORD-004",
                        severity: .high,
                        message: "Session '\(node.agentName)' is \(node.status.rawValue) but retains \(node.activeProcessesCount) unclosed child processes.",
                        remediation: "Ensure SessionLifecycleManager unregisters and terminates subprocesses upon session exit."
                    )
                )
            }

            if (node.status == .completed || node.status == .cancelled) && node.pendingContinuationsCount > 0 {
                violations.append(
                    CoordinationViolation(
                        sessionId: node.id,
                        ruleId: "COORD-005",
                        severity: .high,
                        message: "Session '\(node.agentName)' is \(node.status.rawValue) but retains \(node.pendingContinuationsCount) unresolved confirmation continuations.",
                        remediation: "Resume pending continuations with false/cancellation upon session exit."
                    )
                )
            }
        }

        // Cycle detection in session wait graph
        let deadlocks = detectDeadlocks(sessions: sessions)
        for cycle in deadlocks {
            let names = cycle.compactMap { id in sessions.first(where: { $0.id == id })?.agentName }.joined(separator: " -> ")
            violations.append(
                CoordinationViolation(
                    sessionId: cycle.first ?? UUID(),
                    ruleId: "COORD-006",
                    severity: .critical,
                    message: "Multi-agent deadlock cycle detected: \(names) -> cyclic wait.",
                    remediation: "Break circular dependencies by rejecting reciprocal delegation."
                )
            )
        }

        let penalty = violations.reduce(0.0) { acc, v in
            switch v.severity {
            case .critical: return acc + 35.0
            case .high: return acc + 20.0
            case .medium: return acc + 10.0
            case .low: return acc + 5.0
            case .info: return acc + 1.0
            }
        }

        let score = max(0.0, 100.0 - penalty)
        let hasCriticalOrHigh = violations.contains { $0.severity >= .high }
        let passed = !hasCriticalOrHigh && score >= 80.0

        var recs: [String] = []
        if !passed {
            recs.append("Resolve circular dependencies and ensure proper resource cleanup upon session teardown.")
        }

        return SessionCoordinationAuditReport(
            passed: passed,
            score: score,
            evaluatedSessionsCount: sessions.count,
            detectedDeadlocks: deadlocks,
            violations: violations,
            recommendations: recs
        )
    }

    /// Detects cycles in the waitingOn dependency graph using DFS.
    public static func detectDeadlocks(sessions: [AgentSessionNode]) -> [[UUID]] {
        var waitGraph: [UUID: UUID] = [:]
        for s in sessions {
            if let waitingOn = s.waitingOnSessionId {
                waitGraph[s.id] = waitingOn
            }
        }

        var visited = Set<UUID>()
        var inStack = Set<UUID>()
        var stack: [UUID] = []
        var cycles: [[UUID]] = []

        func dfs(_ current: UUID) {
            visited.insert(current)
            inStack.insert(current)
            stack.append(current)

            if let next = waitGraph[current] {
                if !visited.contains(next) {
                    dfs(next)
                } else if inStack.contains(next) {
                    // Cycle detected!
                    if let startIdx = stack.firstIndex(of: next) {
                        let cycle = Array(stack[startIdx...])
                        cycles.append(cycle)
                    }
                }
            }

            stack.removeLast()
            inStack.remove(current)
        }

        for s in sessions where !visited.contains(s.id) {
            dfs(s.id)
        }

        return cycles
    }
}
