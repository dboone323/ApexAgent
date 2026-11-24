//
//  AgentGovernance.swift
//  ApexAgent
//
//  Issue #181: Agent governance, Agent 365-style: spend limits, value in work completed, block/approve agents.
//

import Foundation
import os

// MARK: - Agent Governance Status & Permissions

public enum AgentGovernanceStatus: String, Codable, Sendable, CaseIterable {
    case approved = "approved"
    case blocked = "blocked"
    case pendingApproval = "pendingApproval"

    public var displayName: String {
        switch self {
        case .approved: return "Approved"
        case .blocked: return "Blocked"
        case .pendingApproval: return "Pending Approval"
        }
    }
}

public enum AgentPermissionFlag: String, Codable, Sendable, CaseIterable, Identifiable {
    case readWorkspace = "read_workspace"
    case writeWorkspace = "write_workspace"
    case shellExecution = "shell_execution"
    case networkAccess = "network_access"
    case credentialAccess = "credential_access"
    case subAgentSpawning = "sub_agent_spawning"
    case fileDeletion = "file_deletion"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .readWorkspace: return "Read Workspace Files"
        case .writeWorkspace: return "Write Workspace Files"
        case .shellExecution: return "Execute Shell Commands"
        case .networkAccess: return "Network & Web Access"
        case .credentialAccess: return "Keychain & Secrets Access"
        case .subAgentSpawning: return "Spawn Sub-Agents"
        case .fileDeletion: return "Delete Files & Directories"
        }
    }
}

// MARK: - Minimal Agent Identity Record

public struct AgentIdentityRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var displayName: String
    public var spaceId: UUID?
    public var status: AgentGovernanceStatus
    public var permissions: Set<AgentPermissionFlag>
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        displayName: String,
        spaceId: UUID? = nil,
        status: AgentGovernanceStatus = .approved,
        permissions: Set<AgentPermissionFlag> = [.readWorkspace],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.spaceId = spaceId
        self.status = status
        self.permissions = permissions
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Spend Limit & Scope

public enum SpendLimitScopeKind: String, Codable, Sendable, CaseIterable {
    case agent = "agent"
    case space = "space"
    case model = "model"
    case user = "user"
    case global = "global"
}

public struct SpendLimitRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String { scopeKey }
    public let scopeKey: String // e.g. "agent:coder", "space:<UUID>", "model:gpt-4o", "user:default", "global"
    public let scopeKind: SpendLimitScopeKind
    public var spendLimit: Double // In USD; default 0.0 (Free-tier safe hard cap)
    public var alertThresholdPercent: Double // Default 0.80 (80%)
    public var currentSpend: Double // In USD
    public var isHardCap: Bool

    public init(
        scopeKey: String,
        scopeKind: SpendLimitScopeKind,
        spendLimit: Double = 0.0,
        alertThresholdPercent: Double = 0.80,
        currentSpend: Double = 0.0,
        isHardCap: Bool = true
    ) {
        self.scopeKey = scopeKey
        self.scopeKind = scopeKind
        self.spendLimit = spendLimit
        self.alertThresholdPercent = alertThresholdPercent
        self.currentSpend = currentSpend
        self.isHardCap = isHardCap
    }

    public var isExceeded: Bool {
        spendLimit > 0.0 ? currentSpend >= spendLimit : currentSpend > 0.0
    }

    public var isApproachingLimit: Bool {
        guard spendLimit > 0.0 else { return false }
        return (currentSpend / spendLimit) >= alertThresholdPercent && !isExceeded
    }

    public var utilizationPercent: Double {
        guard spendLimit > 0.0 else { return currentSpend > 0.0 ? 100.0 : 0.0 }
        return (currentSpend / spendLimit) * 100.0
    }
}

// MARK: - Governance Decision Record (Minimal Decision Audit Log)

public struct GovernanceDecisionRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let actor: String // "user", "admin", "system", "policy"
    public let targetType: String // "agent", "space", "model", "spendLimit"
    public let targetId: String
    public let action: String // "approve", "block", "set_limit", "hard_cap_stop", "alert", "risky_action_gated"
    public let previousValue: String?
    public let newValue: String?
    public let reason: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        actor: String = "user",
        targetType: String,
        targetId: String,
        action: String,
        previousValue: String? = nil,
        newValue: String? = nil,
        reason: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.targetType = targetType
        self.targetId = targetId
        self.action = action
        self.previousValue = previousValue
        self.newValue = newValue
        self.reason = reason
    }
}

// MARK: - Value Analytics Record (Work Completed, Not Just Tokens)

public struct AgentValueRecord: Codable, Sendable, Identifiable, Equatable {
    public var id: String {
        let spacePart = spaceId?.uuidString ?? "global"
        let modelPart = modelId ?? "any"
        return "\(agentId):\(spacePart):\(modelPart)"
    }
    public let agentId: String
    public var displayName: String
    public var spaceId: UUID?
    public var modelId: String?
    public var tasksCompleted: Int
    public var prsMerged: Int
    public var verifiedRuns: Int
    public var totalTokens: Int
    public var totalCost: Double
    public var lastActivityAt: Date

    public init(
        agentId: String,
        displayName: String,
        spaceId: UUID? = nil,
        modelId: String? = nil,
        tasksCompleted: Int = 0,
        prsMerged: Int = 0,
        verifiedRuns: Int = 0,
        totalTokens: Int = 0,
        totalCost: Double = 0.0,
        lastActivityAt: Date = Date()
    ) {
        self.agentId = agentId
        self.displayName = displayName
        self.spaceId = spaceId
        self.modelId = modelId
        self.tasksCompleted = tasksCompleted
        self.prsMerged = prsMerged
        self.verifiedRuns = verifiedRuns
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: - Evaluation Results

public struct GovernanceCheckResult: Sendable, Equatable {
    public let allowed: Bool
    public let refusalReason: String?
    public let isApproachingLimit: Bool
    public let alertMessage: String?
    public let applicableCap: Double
    public let currentSpend: Double

    public init(
        allowed: Bool,
        refusalReason: String? = nil,
        isApproachingLimit: Bool = false,
        alertMessage: String? = nil,
        applicableCap: Double = 0.0,
        currentSpend: Double = 0.0
    ) {
        self.allowed = allowed
        self.refusalReason = refusalReason
        self.isApproachingLimit = isApproachingLimit
        self.alertMessage = alertMessage
        self.applicableCap = applicableCap
        self.currentSpend = currentSpend
    }

    public static let allowed = GovernanceCheckResult(allowed: true)
}

public struct GovernanceActionVerdict: Sendable, Equatable {
    public let allowed: Bool
    public let requiresHumanApproval: Bool
    public let riskCategory: String?
    public let reason: String

    public init(
        allowed: Bool,
        requiresHumanApproval: Bool,
        riskCategory: String? = nil,
        reason: String
    ) {
        self.allowed = allowed
        self.requiresHumanApproval = requiresHumanApproval
        self.riskCategory = riskCategory
        self.reason = reason
    }
}

// MARK: - Agent Governance Manager

public final class AgentGovernanceManager: @unchecked Sendable {
    public static let shared = AgentGovernanceManager()

    public static let agentsDefaultsKey = "apex.agentGovernance.agents"
    public static let spendLimitsDefaultsKey = "apex.agentGovernance.spendLimits"
    public static let valueRecordsDefaultsKey = "apex.agentGovernance.valueRecords"
    public static let decisionLogDefaultsKey = "apex.agentGovernance.decisionLog"

    private static let logger = Logger(subsystem: "com.apexagent.ApexAgent", category: "AgentGovernance")
    private let lock = NSLock()
    private let userDefaults: UserDefaults

    private var agents: [String: AgentIdentityRecord] = [:]
    private var spendLimits: [String: SpendLimitRecord] = [:]
    private var valueRecords: [String: AgentValueRecord] = [:]
    private var decisionLog: [GovernanceDecisionRecord] = []

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadFromStorageOrDefaults()
    }

    // MARK: - State Management & Defaults

    private func loadFromStorageOrDefaults() {
        lock.lock()
        defer { lock.unlock() }

        var loadedAgents: [String: AgentIdentityRecord]?
        if let data = userDefaults.data(forKey: Self.agentsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: AgentIdentityRecord].self, from: data) {
            loadedAgents = decoded
        }

        var loadedSpendLimits: [String: SpendLimitRecord]?
        if let data = userDefaults.data(forKey: Self.spendLimitsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: SpendLimitRecord].self, from: data) {
            loadedSpendLimits = decoded
        }

        var loadedValueRecords: [String: AgentValueRecord]?
        if let data = userDefaults.data(forKey: Self.valueRecordsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: AgentValueRecord].self, from: data) {
            loadedValueRecords = decoded
        }

        var loadedDecisionLog: [GovernanceDecisionRecord]?
        if let data = userDefaults.data(forKey: Self.decisionLogDefaultsKey),
           let decoded = try? JSONDecoder().decode([GovernanceDecisionRecord].self, from: data) {
            loadedDecisionLog = decoded
        }

        if let agents = loadedAgents, !agents.isEmpty {
            self.agents = agents
            self.spendLimits = loadedSpendLimits ?? [:]
            self.valueRecords = loadedValueRecords ?? [:]
            self.decisionLog = loadedDecisionLog ?? []
        } else {
            populateDefaultsLocked()
            persistLocked()
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(agents) {
            userDefaults.set(data, forKey: Self.agentsDefaultsKey)
        }
        if let data = try? encoder.encode(spendLimits) {
            userDefaults.set(data, forKey: Self.spendLimitsDefaultsKey)
        }
        if let data = try? encoder.encode(valueRecords) {
            userDefaults.set(data, forKey: Self.valueRecordsDefaultsKey)
        }
        if let data = try? encoder.encode(decisionLog) {
            userDefaults.set(data, forKey: Self.decisionLogDefaultsKey)
        }
    }

    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }

        agents.removeAll()
        spendLimits.removeAll()
        valueRecords.removeAll()
        decisionLog.removeAll()

        userDefaults.removeObject(forKey: Self.agentsDefaultsKey)
        userDefaults.removeObject(forKey: Self.spendLimitsDefaultsKey)
        userDefaults.removeObject(forKey: Self.valueRecordsDefaultsKey)
        userDefaults.removeObject(forKey: Self.decisionLogDefaultsKey)

        populateDefaultsLocked()
        persistLocked()
    }

    private func populateDefaultsLocked() {
        // Register default known agents with default permissions
        registerDefaultAgentLocked(
            id: "coder",
            displayName: "Codex",
            permissions: [.readWorkspace, .writeWorkspace]
        )
        registerDefaultAgentLocked(
            id: "reviewer",
            displayName: "Reviewer",
            permissions: [.readWorkspace]
        )
        registerDefaultAgentLocked(
            id: "browser",
            displayName: "Browser",
            permissions: [.networkAccess]
        )
        registerDefaultAgentLocked(
            id: "developer",
            displayName: "Developer",
            permissions: [.readWorkspace, .writeWorkspace]
        )
        registerDefaultAgentLocked(
            id: "executor",
            displayName: "Nexus",
            permissions: [.readWorkspace, .shellExecution]
        )
        registerDefaultAgentLocked(
            id: "supervisor",
            displayName: "Apex Prime",
            permissions: Set(AgentPermissionFlag.allCases)
        )

        // Set safe free-tier default caps ($0.0 spend limits)
        let globalLimit = SpendLimitRecord(
            scopeKey: "global",
            scopeKind: .global,
            spendLimit: 0.0,
            alertThresholdPercent: 0.80,
            currentSpend: 0.0,
            isHardCap: true
        )
        spendLimits[globalLimit.scopeKey] = globalLimit
    }

    private func registerDefaultAgentLocked(
        id: String,
        displayName: String,
        permissions: Set<AgentPermissionFlag>
    ) {
        let record = AgentIdentityRecord(
            id: id,
            displayName: displayName,
            spaceId: nil,
            status: .approved,
            permissions: permissions
        )
        agents[id] = record
    }

    // MARK: - Agent Identity & Registry

    public func registerAgent(
        id: String,
        displayName: String,
        spaceId: UUID? = nil,
        status: AgentGovernanceStatus = .approved,
        permissions: Set<AgentPermissionFlag> = [.readWorkspace]
    ) {
        lock.lock()
        defer { lock.unlock() }

        let record = AgentIdentityRecord(
            id: id,
            displayName: displayName,
            spaceId: spaceId,
            status: status,
            permissions: permissions,
            createdAt: Date(),
            updatedAt: Date()
        )
        agents[id] = record
        persistLocked()
    }

    public func agent(for id: String) -> AgentIdentityRecord? {
        lock.lock()
        defer { lock.unlock() }
        return agents[id] ?? agents[id.lowercased()]
    }

    public func allAgents() -> [AgentIdentityRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(agents.values).sorted(by: { $0.displayName < $1.displayName })
    }

    // MARK: - Approve / Block

    public func approveAgent(
        id: String,
        reason: String = "User approved agent",
        actor: String = "user"
    ) {
        lock.lock()
        defer { lock.unlock() }

        let previousStatus = agents[id]?.status.rawValue ?? "unregistered"
        if var record = agents[id] {
            record.status = .approved
            record.updatedAt = Date()
            agents[id] = record
        } else {
            agents[id] = AgentIdentityRecord(
                id: id,
                displayName: id.capitalized,
                status: .approved
            )
        }

        appendDecisionLocked(
            actor: actor,
            targetType: "agent",
            targetId: id,
            action: "approve",
            previousValue: previousStatus,
            newValue: AgentGovernanceStatus.approved.rawValue,
            reason: reason
        )
        persistLocked()
    }

    public func blockAgent(
        id: String,
        reason: String = "User blocked agent",
        actor: String = "user"
    ) {
        lock.lock()
        defer { lock.unlock() }

        let previousStatus = agents[id]?.status.rawValue ?? "unregistered"
        if var record = agents[id] {
            record.status = .blocked
            record.updatedAt = Date()
            agents[id] = record
        } else {
            agents[id] = AgentIdentityRecord(
                id: id,
                displayName: id.capitalized,
                status: .blocked
            )
        }

        appendDecisionLocked(
            actor: actor,
            targetType: "agent",
            targetId: id,
            action: "block",
            previousValue: previousStatus,
            newValue: AgentGovernanceStatus.blocked.rawValue,
            reason: reason
        )
        persistLocked()
    }

    public func isAgentBlocked(id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let record = agents[id] ?? agents[id.lowercased()]
        return record?.status == .blocked
    }

    // MARK: - Spend Limits & Hard Caps

    @discardableResult
    public func setSpendLimit(
        scopeKey: String,
        limit: Double,
        alertThresholdPercent: Double = 0.80,
        reason: String = "Spend limit updated",
        actor: String = "user"
    ) -> Bool {
        let kind: SpendLimitScopeKind
        if scopeKey == "global" {
            kind = .global
        } else if scopeKey.hasPrefix("agent:") {
            kind = .agent
        } else if scopeKey.hasPrefix("space:") {
            kind = .space
        } else if scopeKey.hasPrefix("model:") {
            kind = .model
        } else if scopeKey.hasPrefix("user:") {
            kind = .user
        } else {
            kind = .agent
        }
        return setSpendLimit(scopeKey: scopeKey, scopeKind: kind, limit: limit, alertThresholdPercent: alertThresholdPercent, reason: reason, actor: actor)
    }

    @discardableResult
    public func setSpendLimit(
        scopeKey: String,
        scopeKind: SpendLimitScopeKind,
        limit: Double,
        alertThresholdPercent: Double = 0.80,
        reason: String = "Spend limit updated",
        actor: String = "user"
    ) -> Bool {
        guard limit >= 0.0, limit.isFinite, alertThresholdPercent >= 0.0, alertThresholdPercent.isFinite else {
            lock.lock()
            appendDecisionLocked(
                actor: actor,
                targetType: "spendLimit",
                targetId: scopeKey,
                action: "refused_invalid_limit",
                previousValue: spendLimits[scopeKey]?.spendLimit != nil ? String(format: "$%.2f", spendLimits[scopeKey]!.spendLimit) : nil,
                newValue: "\(limit)",
                reason: "Negative or non-finite spend limit rejected: \(limit)"
            )
            persistLocked()
            lock.unlock()
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        let previous = spendLimits[scopeKey]?.spendLimit
        var record = spendLimits[scopeKey] ?? SpendLimitRecord(
            scopeKey: scopeKey,
            scopeKind: scopeKind,
            spendLimit: limit,
            alertThresholdPercent: alertThresholdPercent
        )
        record.spendLimit = limit
        record.alertThresholdPercent = alertThresholdPercent
        spendLimits[scopeKey] = record

        appendDecisionLocked(
            actor: actor,
            targetType: "spendLimit",
            targetId: scopeKey,
            action: "set_limit",
            previousValue: previous != nil ? String(format: "$%.2f", previous!) : nil,
            newValue: String(format: "$%.2f", limit),
            reason: reason
        )
        persistLocked()
        return true
    }

    public func spendLimit(for scopeKey: String) -> SpendLimitRecord? {
        lock.lock()
        defer { lock.unlock() }
        return spendLimits[scopeKey]
    }

    public func allSpendLimits() -> [SpendLimitRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(spendLimits.values).sorted(by: { $0.scopeKey < $1.scopeKey })
    }

    /// Evaluates if an execution should proceed given agent status and spend limits.
    /// Hard caps stop the run before spending; blocked agents are stopped with refusal reason.
    public func evaluateExecution(
        agentId: String,
        spaceId: UUID? = nil,
        modelId: String? = nil,
        userId: String? = "default",
        estimatedCost: Double = 0.0
    ) -> GovernanceCheckResult {
        lock.lock()
        defer { lock.unlock() }

        let agentRecord = agents[agentId] ?? agents[agentId.lowercased()]
        let displayName = agentRecord?.displayName ?? agentId

        // 1. Check if agent is blocked or pending approval
        if let record = agentRecord {
            if record.status == .blocked {
                let reason = "Agent '\(displayName)' is blocked by governance policy. Unblock or approve the agent to proceed."
                appendDecisionLocked(
                    actor: "policy",
                    targetType: "agent",
                    targetId: agentId,
                    action: "refused_blocked",
                    previousValue: nil,
                    newValue: nil,
                    reason: reason
                )
                return GovernanceCheckResult(
                    allowed: false,
                    refusalReason: reason,
                    applicableCap: 0.0,
                    currentSpend: 0.0
                )
            } else if record.status == .pendingApproval {
                let reason = "Agent '\(displayName)' is pending approval. A user must approve the agent before execution is allowed."
                appendDecisionLocked(
                    actor: "policy",
                    targetType: "agent",
                    targetId: agentId,
                    action: "refused_pending_approval",
                    previousValue: nil,
                    newValue: nil,
                    reason: reason
                )
                return GovernanceCheckResult(
                    allowed: false,
                    refusalReason: reason,
                    applicableCap: 0.0,
                    currentSpend: 0.0
                )
            }
        }

        // 2. Check spend limits in hierarchical order: agent -> space -> model -> user -> global
        let userKey = "user:\(userId ?? "default")"
        let candidateKeys = [
            "agent:\(agentId)",
            spaceId != nil ? "space:\(spaceId!.uuidString)" : nil,
            modelId != nil ? "model:\(modelId!)" : nil,
            userKey,
            "global"
        ].compactMap { $0 }

        var isApproaching = false
        var alertMsg: String?
        var applicableCap: Double = 0.0
        var currentSpendForAlert: Double = 0.0

        for key in candidateKeys {
            if let limitRecord = spendLimits[key] {
                let current = limitRecord.currentSpend
                let cap = limitRecord.spendLimit
                let projected = current + estimatedCost

                // Free-tier safe hard cap check: if cap is 0.0 and cost > 0.0, or projected exceeds cap
                if (cap == 0.0 && estimatedCost > 0.0) || (cap > 0.0 && projected > cap) {
                    let reason = "Spend cap reached for agent '\(displayName)' under scope '\(key)'. Cap: $\(String(format: "%.2f", cap)), current spend: $\(String(format: "%.2f", current)), attempted: $\(String(format: "%.4f", estimatedCost)). Run stopped to prevent unexpected spend."
                    appendDecisionLocked(
                        actor: "policy",
                        targetType: "spendLimit",
                        targetId: key,
                        action: "hard_cap_stop",
                        previousValue: String(format: "$%.2f", current),
                        newValue: String(format: "$%.2f", current),
                        reason: reason
                    )
                    return GovernanceCheckResult(
                        allowed: false,
                        refusalReason: reason,
                        applicableCap: cap,
                        currentSpend: current
                    )
                }

                // Check approaching alert threshold (e.g. 80%)
                if cap > 0.0 && (projected / cap) >= limitRecord.alertThresholdPercent {
                    let pct = Int((projected / cap) * 100)
                    isApproaching = true
                    alertMsg = alertMsg ?? "Notice: Agent '\(displayName)' spend is approaching cap for '\(key)': $\(String(format: "%.2f", projected))/$\(String(format: "%.2f", cap)) (\(pct)%)."
                    applicableCap = cap
                    currentSpendForAlert = max(currentSpendForAlert, current)
                    // Continue evaluating other scopes to ensure hard caps take precedence!
                }
            }
        }

        if isApproaching {
            return GovernanceCheckResult(
                allowed: true,
                isApproachingLimit: true,
                alertMessage: alertMsg,
                applicableCap: applicableCap,
                currentSpend: currentSpendForAlert
            )
        }

        return GovernanceCheckResult.allowed
    }

    /// Records spend actually incurred by a run after it completes.
    /// Hard caps guarantee $0 over-spend if checked prior to execution.
    @discardableResult
    public func recordSpend(
        agentId: String,
        spaceId: UUID? = nil,
        modelId: String? = nil,
        userId: String? = "default",
        amount: Double,
        tokens: Int = 0
    ) -> (isAlert: Bool, alertMessage: String?) {
        lock.lock()
        defer { lock.unlock() }

        let userKey = "user:\(userId ?? "default")"
        let candidateKeys = [
            "agent:\(agentId)",
            spaceId != nil ? "space:\(spaceId!.uuidString)" : nil,
            modelId != nil ? "model:\(modelId!)" : nil,
            userKey,
            "global"
        ].compactMap { $0 }

        var triggeredAlert: String?

        for key in candidateKeys {
            if var limit = spendLimits[key] {
                limit.currentSpend += amount
                spendLimits[key] = limit

                if limit.isApproachingLimit {
                    triggeredAlert = "Notice: Scope '\(key)' spend reached \(Int(limit.utilizationPercent))% of cap ($\(String(format: "%.2f", limit.currentSpend))/$\(String(format: "%.2f", limit.spendLimit)))."
                }
            }
        }

        // Also accumulate into value analytics
        recordValueAccumulationLocked(
            agentId: agentId,
            spaceId: spaceId,
            modelId: modelId,
            tasks: 0,
            prs: 0,
            verified: 0,
            tokens: tokens,
            cost: amount
        )

        persistLocked()

        return (isAlert: triggeredAlert != nil, alertMessage: triggeredAlert)
    }

    // MARK: - Risky Action Governance

    /// Evaluates whether an action (tool invocation or shell command content) mutates workspace state by class.
    public static func isWorkspaceMutatingAction(toolName: String, command: String = "") -> Bool {
        let lowerTool = toolName.lowercased()

        // Tool-level mutation check
        if lowerTool == "write_file" || lowerTool == "file_write" || lowerTool.hasPrefix("write_") || lowerTool.hasSuffix("_write") {
            return true
        }
        if ApprovalAutoReview.isMutatingTool(lowerTool) {
            return true
        }

        // Shell-level mutation check
        let isShellTool = lowerTool == "run_shell_command" || lowerTool == "bash" || lowerTool == "sh" || lowerTool == "zsh"
        if isShellTool && !command.isEmpty {
            return isWorkspaceMutatingShellCommand(command)
        }

        return false
    }

    /// Evaluates whether a shell command content performs workspace mutations (directory creation/removal, file move/copy/touch, redirection, in-place edits).
    public static func isWorkspaceMutatingShellCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // Output redirection (excluding standard redirection to /dev/null or descriptors like 2>&1)
        if trimmed.contains(">") {
            let redirectPattern = #"(?:^|[^&21])(?:>>?)\s*(?!\/dev\/null\b|&[12]\b)\S+"#
            if trimmed.range(of: redirectPattern, options: .regularExpression) != nil {
                return true
            }
        }

        // Mutating command verbs (mkdir, mv, cp, touch, rm, rmdir, unlink, truncate, patch, install)
        let mutatingVerbsPattern = #"(?:^|[|;&\s])(mkdir|mv|cp|touch|rm|rmdir|unlink|truncate|patch|install)\b"#
        if trimmed.range(of: mutatingVerbsPattern, options: .regularExpression) != nil {
            return true
        }

        // Piping to file write utilities (e.g. tee [file])
        let teePattern = #"(?:^|[|;&\s])tee\s+(?!-a\s+\/dev\/null\b|\/dev\/null\b)\S+"#
        if trimmed.range(of: teePattern, options: .regularExpression) != nil {
            return true
        }

        // In-place stream editing (sed -i, perl -i)
        let inPlacePattern = #"(?:^|[|;&\s])(sed|perl)\s+-[a-zA-Z]*i"#
        if trimmed.range(of: inPlacePattern, options: .regularExpression) != nil {
            return true
        }

        // Git workspace mutation commands
        let gitMutationPattern = #"\bgit\s+(commit|merge|rebase|reset|checkout|restore|apply|cherry-pick|pull)\b"#
        if trimmed.range(of: gitMutationPattern, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Evaluates whether an action requires human approval through the existing approval system.
    public func checkActionRisk(
        agentId: String,
        toolName: String,
        command: String = "",
        arguments: String = "",
        directory: String = "/",
        workspacePath: String = "",
        allowlist: ApprovalAllowlist = .shared
    ) -> GovernanceActionVerdict {
        lock.lock()
        let agentRecord = agents[agentId] ?? agents[agentId.lowercased()]
        lock.unlock()

        let displayName = agentRecord?.displayName ?? agentId

        // 0. Check agent blocked / pending approval status
        if agentRecord?.status == .blocked {
            return GovernanceActionVerdict(
                allowed: false,
                requiresHumanApproval: false,
                riskCategory: "agent-blocked",
                reason: "Agent '\(displayName)' is blocked by governance policy. No tool executions or approvals allowed."
            )
        }
        if agentRecord?.status == .pendingApproval {
            return GovernanceActionVerdict(
                allowed: false,
                requiresHumanApproval: false,
                riskCategory: "agent-pending-approval",
                reason: "Agent '\(displayName)' is pending approval. No tool executions or approvals allowed until approved."
            )
        }

        // 1. Check explicit agent permission flag
        let effectiveCmd = command.isEmpty ? arguments : command
        if let permissions = agentRecord?.permissions {
            if (toolName == "run_shell_command" || toolName == "bash" || toolName == "sh" || toolName == "zsh") && !permissions.contains(.shellExecution) {
                lock.lock()
                appendDecisionLocked(
                    actor: "governance",
                    targetType: "agent",
                    targetId: agentId,
                    action: "risky_action_gated",
                    previousValue: nil,
                    newValue: "missing-permission-shell",
                    reason: "Agent '\(displayName)' lacks shell execution permission; human approval required."
                )
                persistLocked()
                lock.unlock()

                return GovernanceActionVerdict(
                    allowed: false,
                    requiresHumanApproval: true,
                    riskCategory: "missing-permission-shell",
                    reason: "Agent '\(displayName)' lacks shell execution permission; human approval required."
                )
            }
            if !permissions.contains(.writeWorkspace) && Self.isWorkspaceMutatingAction(toolName: toolName, command: effectiveCmd) {
                lock.lock()
                appendDecisionLocked(
                    actor: "governance",
                    targetType: "agent",
                    targetId: agentId,
                    action: "risky_action_gated",
                    previousValue: nil,
                    newValue: "missing-permission-write",
                    reason: "Agent '\(displayName)' lacks workspace write permission; human approval required."
                )
                persistLocked()
                lock.unlock()

                return GovernanceActionVerdict(
                    allowed: false,
                    requiresHumanApproval: true,
                    riskCategory: "missing-permission-write",
                    reason: "Agent '\(displayName)' lacks workspace write permission; human approval required."
                )
            }
            if (toolName == "delete_file" || toolName == "file_delete") && !permissions.contains(.fileDeletion) {
                lock.lock()
                appendDecisionLocked(
                    actor: "governance",
                    targetType: "agent",
                    targetId: agentId,
                    action: "risky_action_gated",
                    previousValue: nil,
                    newValue: "missing-permission-deletion",
                    reason: "Agent '\(displayName)' lacks file deletion permission; human approval required."
                )
                persistLocked()
                lock.unlock()

                return GovernanceActionVerdict(
                    allowed: false,
                    requiresHumanApproval: true,
                    riskCategory: "missing-permission-deletion",
                    reason: "Agent '\(displayName)' lacks file deletion permission; human approval required."
                )
            }
        }

        // 2. Delegate to ApprovalAutoReview for standard risk assessment
        let autoReview = ApprovalAutoReview.review(
            toolName: toolName,
            command: command.isEmpty ? arguments : command,
            directory: directory,
            workspacePath: workspacePath,
            allowlist: allowlist
        )

        if !autoReview.shouldAutoApprove {
            lock.lock()
            appendDecisionLocked(
                actor: "governance",
                targetType: "agent",
                targetId: agentId,
                action: "risky_action_gated",
                previousValue: nil,
                newValue: autoReview.assessment.category.rawValue,
                reason: "Action gated for human approval: \(autoReview.assessment.reason)"
            )
            persistLocked()
            lock.unlock()

            return GovernanceActionVerdict(
                allowed: true, // Allowed to proceed to human approval gate
                requiresHumanApproval: true,
                riskCategory: autoReview.assessment.category.rawValue,
                reason: autoReview.assessment.reason
            )
        }

        return GovernanceActionVerdict(
            allowed: true,
            requiresHumanApproval: false,
            riskCategory: autoReview.assessment.category.rawValue,
            reason: autoReview.explanation
        )
    }

    // MARK: - Value Analytics (Work Completed, Not Just Tokens)

    public func recordWorkCompleted(
        agentId: String,
        spaceId: UUID? = nil,
        modelId: String? = nil,
        tasksDone: Int = 0,
        prsMerged: Int = 0,
        verifiedRuns: Int = 0,
        tokens: Int = 0,
        cost: Double = 0.0
    ) {
        lock.lock()
        defer { lock.unlock() }

        recordValueAccumulationLocked(
            agentId: agentId,
            spaceId: spaceId,
            modelId: modelId,
            tasks: tasksDone,
            prs: prsMerged,
            verified: verifiedRuns,
            tokens: tokens,
            cost: cost
        )
        persistLocked()
    }

    private func recordValueAccumulationLocked(
        agentId: String,
        spaceId: UUID?,
        modelId: String?,
        tasks: Int,
        prs: Int,
        verified: Int,
        tokens: Int,
        cost: Double
    ) {
        let spacePart = spaceId?.uuidString ?? "global"
        let modelPart = modelId ?? "any"
        let key = "\(agentId):\(spacePart):\(modelPart)"

        let displayName = agents[agentId]?.displayName ?? agentId
        var record = valueRecords[key] ?? AgentValueRecord(
            agentId: agentId,
            displayName: displayName,
            spaceId: spaceId,
            modelId: modelId
        )

        record.tasksCompleted += tasks
        record.prsMerged += prs
        record.verifiedRuns += verified
        record.totalTokens += tokens
        record.totalCost += cost
        record.lastActivityAt = Date()
        valueRecords[key] = record
    }

    public func valueAnalytics(for agentId: String? = nil) -> [AgentValueRecord] {
        lock.lock()
        defer { lock.unlock() }

        if let id = agentId {
            return valueRecords.values
                .filter { $0.agentId == id }
                .sorted(by: { $0.lastActivityAt > $1.lastActivityAt })
        }
        return Array(valueRecords.values).sorted(by: { $0.displayName < $1.displayName })
    }

    // MARK: - Governance Decision Audit Log

    private func appendDecisionLocked(
        actor: String,
        targetType: String,
        targetId: String,
        action: String,
        previousValue: String?,
        newValue: String?,
        reason: String
    ) {
        let record = GovernanceDecisionRecord(
            actor: actor,
            targetType: targetType,
            targetId: targetId,
            action: action,
            previousValue: previousValue,
            newValue: newValue,
            reason: reason
        )
        decisionLog.append(record)
        if decisionLog.count > 500 {
            decisionLog.removeFirst(decisionLog.count - 500)
        }
        persistLocked()

        Self.logger.info("Governance decision: [\(action, privacy: .public)] on [\(targetId, privacy: .public)] by [\(actor, privacy: .public)] — \(reason, privacy: .public)")
    }

    public func decisionAuditLog(limit: Int = 100) -> [GovernanceDecisionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(decisionLog.suffix(limit).reversed())
    }

    public func clearDecisionLog() {
        lock.lock()
        defer { lock.unlock() }
        decisionLog.removeAll()
        persistLocked()
    }

    // MARK: - Governance JSON Payload (for --json CLI flag)

    public struct GovernanceSummaryPayload: Codable, Sendable {
        public struct AgentItem: Codable, Sendable {
            public let id: String
            public let displayName: String
            public let status: String
            public let permissions: [String]
            public let spendLimit: Double
            public let currentSpend: Double
            public let spendStatus: String
            public let tasksDone: Int
            public let prsMerged: Int
            public let verifiedRuns: Int
            public let tokens: Int
            public let cost: Double
        }
        public let agents: [AgentItem]
        public let recentDecisions: [GovernanceDecisionRecord]
    }

    public func governanceSummaryJSON(for targetAgentId: String? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }

        let targetAgents = targetAgentId != nil
            ? agents.values.filter { $0.id == targetAgentId }
            : Array(agents.values)

        let sortedAgents = targetAgents.sorted(by: { $0.displayName < $1.displayName })

        var agentItems: [GovernanceSummaryPayload.AgentItem] = []
        for agent in sortedAgents {
            let perms = agent.permissions.map { $0.rawValue }.sorted()
            let agentCapKey = "agent:\(agent.id)"
            let capRecord = spendLimits[agentCapKey] ?? spendLimits["global"]
            let capVal = capRecord?.spendLimit ?? 0.0
            let spendVal = capRecord?.currentSpend ?? 0.0

            let capStatus: String
            if capVal > 0.0 {
                let util = (spendVal / capVal) * 100.0
                if spendVal >= capVal {
                    capStatus = "EXCEEDED HARD CAP ($\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                } else if util >= (capRecord?.alertThresholdPercent ?? 0.8) * 100.0 {
                    capStatus = "APPROACHING CAP (\(Int(util))% used: $\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                } else {
                    capStatus = "OK ($\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                }
            } else {
                capStatus = spendVal > 0.0
                    ? "UNAUTHORIZED SPEND ($\(String(format: "%.2f", spendVal))/Free-Tier $0.00 Cap)"
                    : "FREE-TIER SAFE ($0.00 spent / $0.00 cap)"
            }

            let matchingValues = valueRecords.values.filter { $0.agentId == agent.id }
            let totalTasks = matchingValues.reduce(0) { $0 + $1.tasksCompleted }
            let totalPRs = matchingValues.reduce(0) { $0 + $1.prsMerged }
            let totalVerified = matchingValues.reduce(0) { $0 + $1.verifiedRuns }
            let totalTokens = matchingValues.reduce(0) { $0 + $1.totalTokens }
            let totalCost = matchingValues.reduce(0.0) { $0 + $1.totalCost }

            agentItems.append(GovernanceSummaryPayload.AgentItem(
                id: agent.id,
                displayName: agent.displayName,
                status: agent.status.rawValue,
                permissions: perms,
                spendLimit: capVal,
                currentSpend: spendVal,
                spendStatus: capStatus,
                tasksDone: totalTasks,
                prsMerged: totalPRs,
                verifiedRuns: totalVerified,
                tokens: totalTokens,
                cost: totalCost
            ))
        }

        let payload = GovernanceSummaryPayload(
            agents: agentItems,
            recentDecisions: Array(decisionLog.suffix(50).reversed())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    // MARK: - Governance View (Unified Text/Markdown Presentation)

    /// Produces a unified governance summary showing per-agent identity, permissions,
    /// spend vs cap, and work completed (value analytics) in one place.
    public func governanceSummaryView(for targetAgentId: String? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }

        var lines: [String] = []
        lines.append("================================================================================")
        lines.append("APEXAGENT AGENT GOVERNANCE REGISTRY & VALUE DASHBOARD")
        lines.append("================================================================================")

        let targetAgents = targetAgentId != nil
            ? agents.values.filter { $0.id == targetAgentId }
            : Array(agents.values)

        let sortedAgents = targetAgents.sorted(by: { $0.displayName < $1.displayName })

        if sortedAgents.isEmpty {
            lines.append("No registered agents found.")
            return lines.joined(separator: "\n")
        }

        for agent in sortedAgents {
            lines.append("\n[Agent: \(agent.displayName)] (ID: \(agent.id))")
            lines.append("  Status:      \(agent.status.displayName.uppercased())")
            let spaceLabel = agent.spaceId?.uuidString.prefix(8) ?? "Global"
            lines.append("  Space Scope: \(spaceLabel)")

            let perms = agent.permissions.map { $0.rawValue }.sorted().joined(separator: ", ")
            lines.append("  Permissions: [\(perms.isEmpty ? "none" : perms)]")

            // Spend vs Cap
            let agentCapKey = "agent:\(agent.id)"
            let capRecord = spendLimits[agentCapKey] ?? spendLimits["global"]
            let capVal = capRecord?.spendLimit ?? 0.0
            let spendVal = capRecord?.currentSpend ?? 0.0
            let capStatus: String
            if capVal > 0.0 {
                let util = (spendVal / capVal) * 100.0
                if spendVal >= capVal {
                    capStatus = "EXCEEDED HARD CAP ($\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                } else if util >= (capRecord?.alertThresholdPercent ?? 0.8) * 100.0 {
                    capStatus = "APPROACHING CAP (\(Int(util))% used: $\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                } else {
                    capStatus = "OK ($\(String(format: "%.2f", spendVal))/$\(String(format: "%.2f", capVal)))"
                }
            } else {
                capStatus = spendVal > 0.0
                    ? "UNAUTHORIZED SPEND ($\(String(format: "%.2f", spendVal))/Free-Tier $0.00 Cap)"
                    : "FREE-TIER SAFE ($0.00 spent / $0.00 cap)"
            }
            lines.append("  Spend vs Cap: \(capStatus)")

            // Value analytics (Work completed, not just tokens)
            let matchingValues = valueRecords.values.filter { $0.agentId == agent.id }
            let totalTasks = matchingValues.reduce(0) { $0 + $1.tasksCompleted }
            let totalPRs = matchingValues.reduce(0) { $0 + $1.prsMerged }
            let totalVerified = matchingValues.reduce(0) { $0 + $1.verifiedRuns }
            let totalTokens = matchingValues.reduce(0) { $0 + $1.totalTokens }
            let totalCost = matchingValues.reduce(0.0) { $0 + $1.totalCost }

            lines.append("  Work Value:  Tasks Done: \(totalTasks) | PRs Merged: \(totalPRs) | Verified Runs: \(totalVerified)")
            lines.append("  Efficiency:  Tokens: \(totalTokens) | Cost: $\(String(format: "%.4f", totalCost))")
        }

        lines.append("\n--------------------------------------------------------------------------------")
        lines.append("Recent Governance Decisions (Audit Log):")
        let recent = decisionLog.suffix(5).reversed()
        if recent.isEmpty {
            lines.append("  No governance decisions logged.")
        } else {
            let isoFormatter = ISO8601DateFormatter()
            for d in recent {
                let ts = isoFormatter.string(from: d.timestamp)
                lines.append("  [\(ts)] [\(d.actor)] \(d.action) on \(d.targetId): \(d.reason)")
            }
        }
        lines.append("================================================================================")

        return lines.joined(separator: "\n")
    }
}
