import Foundation

// MARK: - Speculative Tool Execution DAG & Transaction Rollback Gate (Batch 79)

/// Single step node in a speculative tool execution graph.
public struct SpeculativeStepNode: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let toolName: String
    public let arguments: String
    public let dependsOn: [String]
    public let isSpeculative: Bool
    public let hasRollbackHandler: Bool

    public init(
        id: String,
        toolName: String,
        arguments: String = "{}",
        dependsOn: [String] = [],
        isSpeculative: Bool = true,
        hasRollbackHandler: Bool = false
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.dependsOn = dependsOn
        self.isSpeculative = isSpeculative
        self.hasRollbackHandler = hasRollbackHandler
    }
}

/// Violation detected during speculative DAG analysis.
public struct SpeculativeExecutionViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let stepId: String?
    public let isFatal: Bool

    public init(code: String, message: String, stepId: String? = nil, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.stepId = stepId
        self.isFatal = isFatal
    }
}

/// Report produced by auditing a speculative tool execution graph.
public struct SpeculativeExecutionAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalStepsCount: Int
    public let isAcyclic: Bool
    public let executionOrder: [String]?
    public let detectedCycle: [String]?
    public let allSpeculativeStepsSideEffectFree: Bool
    public let violations: [SpeculativeExecutionViolation]

    public init(
        passed: Bool,
        score: Double,
        totalStepsCount: Int,
        isAcyclic: Bool,
        executionOrder: [String]?,
        detectedCycle: [String]?,
        allSpeculativeStepsSideEffectFree: Bool,
        violations: [SpeculativeExecutionViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalStepsCount = totalStepsCount
        self.isAcyclic = isAcyclic
        self.executionOrder = executionOrder
        self.detectedCycle = detectedCycle
        self.allSpeculativeStepsSideEffectFree = allSpeculativeStepsSideEffectFree
        self.violations = violations
    }
}

/// Auditor for speculative tool execution DAGs, cycle detection, and rollback safety.
public enum SpeculativeExecutionAuditor {

    /// Safe tools permitted to run speculatively without user confirmation.
    public static let readOnlySpeculativeTools: Set<String> = [
        "read_file", "file_search", "list_directory",
        "get_system_info", "search_memory", "query_logs", "fetch_web_url"
    ]

    // MARK: - Cycle Detection & Topological Sort

    /// Detects if a cycle exists in the dependency graph. Returns cycle path if found.
    public static func detectCycles(steps: [SpeculativeStepNode]) -> [String]? {
        var adj: [String: [String]] = [:]
        for step in steps {
            adj[step.id] = step.dependsOn
        }

        var visited: [String: Int] = [:] // 0: unvisited, 1: visiting (in stack), 2: visited
        var stack: [String] = []

        func dfs(_ node: String) -> [String]? {
            visited[node] = 1
            stack.append(node)

            if let neighbors = adj[node] {
                for neighbor in neighbors {
                    if visited[neighbor] == 1 {
                        // Back edge found (cycle)
                        if let cycleStart = stack.firstIndex(of: neighbor) {
                            return Array(stack[cycleStart...]) + [neighbor]
                        }
                        return [node, neighbor]
                    } else if visited[neighbor] == 0 || visited[neighbor] == nil {
                        if let cycle = dfs(neighbor) {
                            return cycle
                        }
                    }
                }
            }

            stack.removeLast()
            visited[node] = 2
            return nil
        }

        for step in steps {
            if visited[step.id] == nil || visited[step.id] == 0 {
                if let cycle = dfs(step.id) {
                    return cycle
                }
            }
        }

        return nil
    }

    /// Computes a valid topological execution order (dependencies execute before dependents).
    public static func computeExecutionOrder(steps: [SpeculativeStepNode]) -> [String]? {
        guard detectCycles(steps: steps) == nil else { return nil }

        var inDegree: [String: Int] = [:]
        var dependents: [String: [String]] = [:]

        for step in steps {
            inDegree[step.id] = step.dependsOn.count
            for dep in step.dependsOn {
                dependents[dep, default: []].append(step.id)
            }
        }

        var queue = steps.filter { ($0.dependsOn.isEmpty) }.map(\.id)
        var order: [String] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            order.append(current)

            if let children = dependents[current] {
                for child in children {
                    inDegree[child, default: 0] -= 1
                    if inDegree[child] == 0 {
                        queue.append(child)
                    }
                }
            }
        }

        return order.count == steps.count ? order : nil
    }

    // MARK: - Graph Audit

    /// Audits a speculative step graph for cycles, side-effect safety, and rollback handler coverage.
    public static func auditExecutionGraph(
        steps: [SpeculativeStepNode],
        maxConcurrentSpeculations: Int = 5
    ) -> SpeculativeExecutionAuditReport {
        var violations: [SpeculativeExecutionViolation] = []
        var sideEffectFree = true

        guard !steps.isEmpty else {
            violations.append(SpeculativeExecutionViolation(
                code: "EMPTY_EXECUTION_GRAPH",
                message: "Speculative execution graph has zero steps."
            ))
            return SpeculativeExecutionAuditReport(
                passed: false,
                score: 0.0,
                totalStepsCount: 0,
                isAcyclic: false,
                executionOrder: nil,
                detectedCycle: nil,
                allSpeculativeStepsSideEffectFree: false,
                violations: violations
            )
        }

        // 1. Dependency Cycle Check
        let detectedCycle = detectCycles(steps: steps)
        let isAcyclic = detectedCycle == nil
        if let cycle = detectedCycle {
            violations.append(SpeculativeExecutionViolation(
                code: "DEPENDENCY_CYCLE_DETECTED",
                message: "Circular dependency detected along path: \(cycle.joined(separator: " -> "))."
            ))
        }

        // 2. Missing dependency target check
        let stepIds = Set(steps.map(\.id))
        for step in steps {
            for dep in step.dependsOn {
                if !stepIds.contains(dep) {
                    violations.append(SpeculativeExecutionViolation(
                        code: "UNKNOWN_DEPENDENCY_TARGET",
                        message: "Step '\(step.id)' depends on non-existent step '\(dep)'.",
                        stepId: step.id
                    ))
                }
            }
        }

        // 3. Side-Effect Safety & Rollback Audit
        var speculativeCount = 0
        for step in steps {
            if step.isSpeculative {
                speculativeCount += 1
                let isSafe = readOnlySpeculativeTools.contains(step.toolName)
                if !isSafe {
                    sideEffectFree = false
                    violations.append(SpeculativeExecutionViolation(
                        code: "MUTATING_SPECULATIVE_TOOL",
                        message: "Tool '\(step.toolName)' has side effects and cannot run speculatively without confirmation.",
                        stepId: step.id
                    ))
                }
            } else {
                // Non-speculative mutating tools must register a rollback handler
                let isReadOnly = readOnlySpeculativeTools.contains(step.toolName)
                if !isReadOnly && !step.hasRollbackHandler {
                    violations.append(SpeculativeExecutionViolation(
                        code: "MISSING_ROLLBACK_HANDLER",
                        message: "Mutating step '\(step.toolName)' does not have a registered rollback compensation action.",
                        stepId: step.id,
                        isFatal: false
                    ))
                }
            }
        }

        // 4. Concurrency cap check
        if speculativeCount > maxConcurrentSpeculations {
            violations.append(SpeculativeExecutionViolation(
                code: "SPECULATION_CAP_EXCEEDED",
                message: "Pipeline contains \(speculativeCount) speculative steps, exceeding concurrency cap of \(maxConcurrentSpeculations).",
                isFatal: false
            ))
        }

        let executionOrder = computeExecutionOrder(steps: steps)
        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 85.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 30.0)

        return SpeculativeExecutionAuditReport(
            passed: passed,
            score: score,
            totalStepsCount: steps.count,
            isAcyclic: isAcyclic,
            executionOrder: executionOrder,
            detectedCycle: detectedCycle,
            allSpeculativeStepsSideEffectFree: sideEffectFree,
            violations: violations
        )
    }
}
