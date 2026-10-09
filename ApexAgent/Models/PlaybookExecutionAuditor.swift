import Foundation

// MARK: - Team Playbook Execution Graph & Compensation Gate (Batch 85)

/// Represents an execution node in a team playbook DAG.
public struct PlaybookStageNode: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let dependencies: [String]
    public let isMutating: Bool
    public let compensationStageId: String?
    public let requiredRoleIds: [String]
    public let promptTemplate: String

    public init(
        id: String,
        name: String,
        dependencies: [String] = [],
        isMutating: Bool = false,
        compensationStageId: String? = nil,
        requiredRoleIds: [String] = [],
        promptTemplate: String = ""
    ) {
        self.id = id
        self.name = name
        self.dependencies = dependencies
        self.isMutating = isMutating
        self.compensationStageId = compensationStageId
        self.requiredRoleIds = requiredRoleIds
        self.promptTemplate = promptTemplate
    }
}

/// Violation detected in playbook execution graph or variable binding.
public struct PlaybookGraphViolation: Sendable, Codable, Equatable {
    public let stageId: String?
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(stageId: String? = nil, code: String, message: String, isFatal: Bool = true) {
        self.stageId = stageId
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Comprehensive report from auditing playbook execution DAG, bindings, and compensations.
public struct PlaybookGraphAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let totalStagesCount: Int
    public let topologicalOrder: [String]
    public let unresolvedDependencies: [String]
    public let unboundVariables: [String]
    public let missingCompensations: [String]
    public let violations: [PlaybookGraphViolation]

    public init(
        passed: Bool,
        score: Double,
        totalStagesCount: Int,
        topologicalOrder: [String],
        unresolvedDependencies: [String],
        unboundVariables: [String],
        missingCompensations: [String],
        violations: [PlaybookGraphViolation]
    ) {
        self.passed = passed
        self.score = score
        self.totalStagesCount = totalStagesCount
        self.topologicalOrder = topologicalOrder
        self.unresolvedDependencies = unresolvedDependencies
        self.unboundVariables = unboundVariables
        self.missingCompensations = missingCompensations
        self.violations = violations
    }
}

/// Auditor for multi-agent playbook execution graphs, cycle detection, variable interpolation, and rollback compensations.
public enum PlaybookExecutionAuditor {

    // MARK: - Variable Interpolation

    private static let variableRegex: NSRegularExpression = {
        // Matches {{var_name}} or ${var_name}
        try! NSRegularExpression(pattern: #"\{\{([a-zA-Z0-9_]+)\}\}|\$\{([a-zA-Z0-9_]+)\}"#, options: [])
    }()

    /// Interpolates variable bindings into template and returns unbound variables.
    public static func interpolateVariables(
        template: String,
        variables: [String: String]
    ) -> (interpolated: String, unbound: [String]) {
        let nsTemplate = template as NSString
        let matches = variableRegex.matches(in: template, options: [], range: NSRange(location: 0, length: nsTemplate.length))

        var unbound: Set<String> = []
        var result = template

        // Collect all variable keys referenced in template
        for match in matches {
            let keyRange = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
            if keyRange.location != NSNotFound {
                let key = nsTemplate.substring(with: keyRange)
                if let val = variables[key] {
                    let fullPattern1 = "{{\(key)}}"
                    let fullPattern2 = "${\(key)}"
                    result = result.replacingOccurrences(of: fullPattern1, with: val)
                    result = result.replacingOccurrences(of: fullPattern2, with: val)
                } else {
                    unbound.insert(key)
                }
            }
        }

        return (result, Array(unbound).sorted())
    }

    // MARK: - Cycle Detection and Topological Sort

    /// Computes topological order of stage execution using Kahn's algorithm. Returns nil if cycle is detected.
    public static func computeTopologicalOrder(stages: [PlaybookStageNode]) -> [String]? {
        let stageIds = Set(stages.map(\.id))
        var inDegree: [String: Int] = [:]
        var adjacency: [String: [String]] = [:]

        for stage in stages {
            inDegree[stage.id] = 0
            adjacency[stage.id] = []
        }

        for stage in stages {
            for dep in stage.dependencies where stageIds.contains(dep) {
                adjacency[dep, default: []].append(stage.id)
                inDegree[stage.id, default: 0] += 1
            }
        }

        var queue: [String] = stages.filter { inDegree[$0.id] == 0 }.map(\.id)
        var order: [String] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            order.append(current)

            for neighbor in adjacency[current, default: []] {
                inDegree[neighbor, default: 0] -= 1
                if inDegree[neighbor] == 0 {
                    queue.append(neighbor)
                }
            }
        }

        if order.count == stages.count {
            return order
        }
        return nil
    }

    /// Detects cycles using Depth-First Search with 3-color marking. Returns cycle path if present.
    public static func detectCyclePath(stages: [PlaybookStageNode]) -> [String]? {
        let stageIds = Set(stages.map(\.id))
        var adjacency: [String: [String]] = [:]
        for stage in stages {
            // Edge from dependency -> stage
            for dep in stage.dependencies where stageIds.contains(dep) {
                adjacency[dep, default: []].append(stage.id)
            }
        }

        enum Color { case white, gray, black }
        var colors: [String: Color] = [:]
        for stage in stages { colors[stage.id] = .white }

        var path: [String] = []

        func dfs(_ node: String) -> [String]? {
            colors[node] = .gray
            path.append(node)

            for neighbor in adjacency[node, default: []] {
                if colors[neighbor] == .gray {
                    // Cycle detected!
                    if let firstIndex = path.firstIndex(of: neighbor) {
                        return Array(path[firstIndex...]) + [neighbor]
                    }
                    return path + [neighbor]
                }
                if colors[neighbor] == .white {
                    if let cycle = dfs(neighbor) {
                        return cycle
                    }
                }
            }

            colors[node] = .black
            path.removeLast()
            return nil
        }

        for stage in stages where colors[stage.id] == .white {
            if let cycle = dfs(stage.id) {
                return cycle
            }
        }

        return nil
    }

    // MARK: - Full Execution Graph Audit

    /// Audits the entire playbook execution graph for dependency resolution, DAG acyclicity, variable bindings, and rollback compensations.
    public static func auditExecutionGraph(
        stages: [PlaybookStageNode],
        variables: [String: String] = [:]
    ) -> PlaybookGraphAuditReport {
        var violations: [PlaybookGraphViolation] = []
        var unresolvedDeps: [String] = []
        var allUnbound: Set<String> = []
        var missingCompensations: [String] = []

        let stageIdMap = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })

        if stages.isEmpty {
            violations.append(PlaybookGraphViolation(
                code: "EMPTY_PLAYBOOK_GRAPH",
                message: "Playbook has no stage nodes."
            ))
            return PlaybookGraphAuditReport(
                passed: false,
                score: 0.0,
                totalStagesCount: 0,
                topologicalOrder: [],
                unresolvedDependencies: [],
                unboundVariables: [],
                missingCompensations: [],
                violations: violations
            )
        }

        // 1. Unresolved dependency checks
        for stage in stages {
            for dep in stage.dependencies {
                if stageIdMap[dep] == nil {
                    unresolvedDeps.append("\(stage.id)->\(dep)")
                    violations.append(PlaybookGraphViolation(
                        stageId: stage.id,
                        code: "UNRESOLVED_DEPENDENCY",
                        message: "Stage '\(stage.id)' depends on non-existent stage '\(dep)'."
                    ))
                }
            }
        }

        // 2. Cycle detection & topological order
        let topoOrder: [String]
        if let order = computeTopologicalOrder(stages: stages) {
            topoOrder = order
        } else {
            let cycle = detectCyclePath(stages: stages) ?? []
            let cycleStr = cycle.joined(separator: " -> ")
            violations.append(PlaybookGraphViolation(
                code: "CYCLIC_DEPENDENCY",
                message: "Cycle detected in playbook execution graph: \(cycleStr)"
            ))
            topoOrder = []
        }

        // 3. Variable binding check
        for stage in stages {
            let (_, unbound) = interpolateVariables(template: stage.promptTemplate, variables: variables)
            for varName in unbound {
                allUnbound.insert(varName)
                violations.append(PlaybookGraphViolation(
                    stageId: stage.id,
                    code: "UNBOUND_VARIABLE",
                    message: "Stage '\(stage.id)' requires variable '{{\(varName)}}' which is not provided."
                ))
            }
        }

        // 4. Compensation / Rollback validation
        for stage in stages where stage.isMutating {
            if let compId = stage.compensationStageId {
                if stageIdMap[compId] == nil {
                    missingCompensations.append(stage.id)
                    violations.append(PlaybookGraphViolation(
                        stageId: stage.id,
                        code: "INVALID_COMPENSATION_TARGET",
                        message: "Mutating stage '\(stage.id)' specifies non-existent compensation stage '\(compId)'."
                    ))
                }
            } else {
                missingCompensations.append(stage.id)
                violations.append(PlaybookGraphViolation(
                    stageId: stage.id,
                    code: "MISSING_COMPENSATION_STAGE",
                    message: "Mutating stage '\(stage.id)' has no compensation rollback stage.",
                    isFatal: false
                ))
            }
        }

        // 5. Score calculation
        let fatalCount = violations.filter(\.isFatal).count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let passed = fatalCount == 0

        var score = 100.0 - Double(fatalCount) * 25.0 - Double(nonFatalCount) * 10.0
        score = max(0.0, min(100.0, score))

        return PlaybookGraphAuditReport(
            passed: passed,
            score: score,
            totalStagesCount: stages.count,
            topologicalOrder: topoOrder,
            unresolvedDependencies: unresolvedDeps,
            unboundVariables: Array(allUnbound).sorted(),
            missingCompensations: missingCompensations,
            violations: violations
        )
    }
}
