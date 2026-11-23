//
//  ModelRouter.swift
//  ApexAgent
//
//  Issue #179: Model router / orchestrator: cheapest capable model per task, with free-tier fallback.
//

import Foundation
import os

// MARK: - Task Kinds

/// Categories of tasks routed by ModelRouter.
public enum ModelTaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case classification = "classification"
    case routing = "routing"
    case verification = "verification"
    case coding = "coding"
    case reasoning = "reasoning"
    case multimodal = "multimodal"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classification: return "Classification"
        case .routing: return "Routing & Intent"
        case .verification: return "Verification & Linting"
        case .coding: return "Heavy Coding"
        case .reasoning: return "Deep Reasoning & Planning"
        case .multimodal: return "Multimodal (Vision / Attachments)"
        }
    }

    public var isLight: Bool {
        switch self {
        case .classification, .routing, .verification:
            return true
        case .coding, .reasoning, .multimodal:
            return false
        }
    }
}

// MARK: - Routable Model

/// Metadata and capabilities for a model participating in routing.
public struct RoutableModel: Identifiable, Sendable, Codable, Equatable {
    public let id: String
    public let provider: ModelProvider
    public let displayName: String
    public let supportedTasks: Set<ModelTaskKind>
    public let isFree: Bool
    public let estimatedCostPer1kTokens: Double
    public let contextWindow: Int
    public let isLocal: Bool
    public let speedRating: String

    public init(
        id: String,
        provider: ModelProvider,
        displayName: String,
        supportedTasks: Set<ModelTaskKind>,
        isFree: Bool,
        estimatedCostPer1kTokens: Double = 0.0,
        contextWindow: Int = 32768,
        isLocal: Bool = true,
        speedRating: String = "fast"
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.supportedTasks = supportedTasks
        self.isFree = isFree
        self.estimatedCostPer1kTokens = estimatedCostPer1kTokens
        self.contextWindow = contextWindow
        self.isLocal = isLocal
        self.speedRating = speedRating
    }
}

// MARK: - Task Routing Rule

/// User-visible and editable routing rule, optionally scoped to a Space.
public struct TaskRoutingRule: Codable, Sendable, Equatable, Identifiable {
    public var id: String {
        let spacePart = spaceId?.uuidString ?? "global"
        return "\(spacePart):\(taskKind.rawValue)"
    }
    public var spaceId: UUID?
    public var taskKind: ModelTaskKind
    public var preferredModelId: String?
    public var allowPaidEscalation: Bool
    public var customCostLimit: Double

    public init(
        spaceId: UUID? = nil,
        taskKind: ModelTaskKind,
        preferredModelId: String? = nil,
        allowPaidEscalation: Bool = false,
        customCostLimit: Double = 0.0
    ) {
        self.spaceId = spaceId
        self.taskKind = taskKind
        self.preferredModelId = preferredModelId
        self.allowPaidEscalation = allowPaidEscalation
        self.customCostLimit = customCostLimit
    }
}

// MARK: - Paid Escalation Gating

/// Approval state for escalating beyond free-tier models.
public struct PaidEscalationApproval: Sendable, Equatable {
    public let isApproved: Bool
    public let userApprovalToken: String?
    public let authorizedSpendCap: Double

    public init(
        isApproved: Bool = false,
        userApprovalToken: String? = nil,
        authorizedSpendCap: Double = 0.0
    ) {
        self.isApproved = isApproved
        self.userApprovalToken = userApprovalToken
        self.authorizedSpendCap = authorizedSpendCap
    }

    public static let refused = PaidEscalationApproval(isApproved: false)
}

// MARK: - Routing Decision

/// A concrete logged routing decision with latency, cost, and reason.
public struct RoutingDecision: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let spaceId: UUID?
    public let taskKind: ModelTaskKind
    public let selectedModelId: String
    public let selectedProvider: ModelProvider
    public let reason: String
    public let isFree: Bool
    public let estimatedCost: Double
    public let latencyMs: Double
    public let fallbackNotice: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        spaceId: UUID? = nil,
        taskKind: ModelTaskKind,
        selectedModelId: String,
        selectedProvider: ModelProvider,
        reason: String,
        isFree: Bool,
        estimatedCost: Double = 0.0,
        latencyMs: Double = 0.0,
        fallbackNotice: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.spaceId = spaceId
        self.taskKind = taskKind
        self.selectedModelId = selectedModelId
        self.selectedProvider = selectedProvider
        self.reason = reason
        self.isFree = isFree
        self.estimatedCost = estimatedCost
        self.latencyMs = latencyMs
        self.fallbackNotice = fallbackNotice
    }
}

// MARK: - Routing Resolution Result

public enum RoutingResolutionResult: Sendable, Equatable {
    case routed(decision: RoutingDecision)
    case paidEscalationRefused(reason: String, costNote: String)
    case fallbackExhausted(reason: String)

    public var decision: RoutingDecision? {
        if case .routed(let dec) = self { return dec }
        return nil
    }

    public var isSuccess: Bool {
        if case .routed = self { return true }
        return false
    }
}

// MARK: - Model Router

/// Single source of truth for cost-optimal task routing, free-tier first selection,
/// daily-limit fallback chains, and gated paid escalation.
public final class ModelRouter: @unchecked Sendable {
    public static let shared = ModelRouter()

    private static let logger = Logger(subsystem: "com.apexagent.ApexAgent", category: "ModelRouter")

    private let lock = NSLock()

    // Model Catalog
    private var models: [String: RoutableModel] = [:]

    // Per-space / per-task rules: key is rule.id
    private var rulesMap: [String: TaskRoutingRule] = [:]

    // Daily limit tracker: modelId -> reason
    private var dailyLimitHits: [String: String] = [:]

    // Decision log history
    private var decisions: [RoutingDecision] = []

    public init() {
        registerDefaultModels()
    }

    // MARK: - Model Catalog Initialization

    private func registerDefaultModels() {
        // Free on-device light model: AFM 3 On-Device
        let afmOnDevice = RoutableModel(
            id: "appleOnDevice",
            provider: .appleOnDevice,
            displayName: "Apple Intelligence (AFM 3 On-Device)",
            supportedTasks: [.classification, .routing, .verification],
            isFree: true,
            estimatedCostPer1kTokens: 0.0,
            contextWindow: 4096,
            isLocal: true,
            speedRating: "instant"
        )

        // Free local heavy model: Local Ollama (Qwen 2.5 Coder / Llama 3)
        let localOllama = RoutableModel(
            id: "localOllama",
            provider: .localOllama,
            displayName: "Local Ollama (Qwen 2.5 Coder 7B)",
            supportedTasks: [.coding, .reasoning, .verification, .classification],
            isFree: true,
            estimatedCostPer1kTokens: 0.0,
            contextWindow: 32768,
            isLocal: true,
            speedRating: "fast"
        )

        // Free local MLX model: Local MLX-LM
        let localMLX = RoutableModel(
            id: "localMLX",
            provider: .localMLX,
            displayName: "Local MLX-LM",
            supportedTasks: [.coding, .reasoning, .verification],
            isFree: true,
            estimatedCostPer1kTokens: 0.0,
            contextWindow: 32768,
            isLocal: true,
            speedRating: "veryFast"
        )

        // Free Apple Private Cloud Compute: Apple PCC
        let applePCC = RoutableModel(
            id: "applePCC",
            provider: .applePCC,
            displayName: "Apple Private Cloud Compute (PCC)",
            supportedTasks: [.reasoning, .coding],
            isFree: true,
            estimatedCostPer1kTokens: 0.0,
            contextWindow: 32768,
            isLocal: false,
            speedRating: "fast"
        )

        // Free Cloud Tier: Google Gemini Free Tier
        let cloudGemini = RoutableModel(
            id: "cloudGemini",
            provider: .cloudGemini,
            displayName: "Google Gemini Cloud (Free Tier)",
            supportedTasks: [.multimodal, .reasoning, .coding, .classification],
            isFree: true,
            estimatedCostPer1kTokens: 0.0,
            contextWindow: 1048576,
            isLocal: false,
            speedRating: "veryFast"
        )

        // Paid Model: Anthropic Claude 3.5 Sonnet
        let claudeSonnet = RoutableModel(
            id: "anthropic-claude-3-5-sonnet",
            provider: .anthropic,
            displayName: "Claude 3.5 Sonnet",
            supportedTasks: [.coding, .reasoning, .multimodal, .verification],
            isFree: false,
            estimatedCostPer1kTokens: 0.003,
            contextWindow: 200000,
            isLocal: false,
            speedRating: "fast"
        )

        // Paid Model: OpenAI GPT-4o
        let gpt4o = RoutableModel(
            id: "openai-gpt-4o",
            provider: .openAICompatible,
            displayName: "OpenAI GPT-4o",
            supportedTasks: [.coding, .reasoning, .multimodal, .classification],
            isFree: false,
            estimatedCostPer1kTokens: 0.0025,
            contextWindow: 128000,
            isLocal: false,
            speedRating: "fast"
        )

        models[afmOnDevice.id] = afmOnDevice
        models[localOllama.id] = localOllama
        models[localMLX.id] = localMLX
        models[applePCC.id] = applePCC
        models[cloudGemini.id] = cloudGemini
        models[claudeSonnet.id] = claudeSonnet
        models[gpt4o.id] = gpt4o
    }

    public func allModels() -> [RoutableModel] {
        lock.lock()
        defer { lock.unlock() }
        return Array(models.values)
    }

    public func model(for id: String) -> RoutableModel? {
        lock.lock()
        defer { lock.unlock() }
        return models[id]
    }

    // MARK: - Rules Management (Per-Space / Per-Task)

    public func rules(for spaceId: UUID?) -> [TaskRoutingRule] {
        lock.lock()
        defer { lock.unlock() }
        return rulesMap.values.filter { rule in
            if let sid = spaceId {
                return rule.spaceId == sid
            } else {
                return rule.spaceId == nil
            }
        }
    }

    public func setRule(_ rule: TaskRoutingRule, for spaceId: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        var updated = rule
        updated.spaceId = spaceId
        rulesMap[updated.id] = updated
        Self.logger.info("Updated routing rule: [\(updated.id, privacy: .public)] -> preferred: \(updated.preferredModelId ?? "none", privacy: .public)")
    }

    public func resetRules(for spaceId: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let sid = spaceId {
            rulesMap = rulesMap.filter { $0.value.spaceId != sid }
        } else {
            rulesMap.removeAll()
        }
    }

    // MARK: - Daily Limit Simulation & Management

    public func recordDailyLimitHit(modelId: String, reason: String = "Daily quota reached") {
        lock.lock()
        dailyLimitHits[modelId] = reason
        lock.unlock()
        Self.logger.warning("Daily limit recorded for model [\(modelId, privacy: .public)]: \(reason, privacy: .public)")
    }

    public func clearDailyLimits() {
        lock.lock()
        dailyLimitHits.removeAll()
        lock.unlock()
    }

    public func isDailyLimitHit(modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dailyLimitHits[modelId] != nil
    }

    public func dailyLimitReason(for modelId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return dailyLimitHits[modelId]
    }

    public func candidatePriority(model: RoutableModel, taskKind: ModelTaskKind) -> Int {
        if !model.isFree { return 1000 }
        switch taskKind {
        case .classification, .routing, .verification:
            if model.id == "appleOnDevice" { return 10 }
            if model.id == "localOllama" { return 20 }
            if model.id == "cloudGemini" { return 30 }
            if model.id == "localMLX" { return 40 }
            return 50
        case .coding:
            if model.id == "localOllama" { return 10 }
            if model.id == "cloudGemini" { return 20 }
            if model.id == "localMLX" { return 30 }
            if model.id == "applePCC" { return 40 }
            return 50
        case .reasoning:
            if model.id == "localOllama" { return 10 }
            if model.id == "applePCC" { return 20 }
            if model.id == "cloudGemini" { return 30 }
            if model.id == "localMLX" { return 40 }
            return 50
        case .multimodal:
            if model.id == "cloudGemini" { return 10 }
            if model.id == "localOllama" { return 20 }
            return 50
        }
    }

    // MARK: - Routing Engine

    /// Routes a task kind to the cheapest capable model with free-tier preference,
    /// limit fallback handling, and gated paid escalation.
    public func route(
        taskKind: ModelTaskKind,
        spaceId: UUID? = nil,
        hasAttachments: Bool = false,
        preferredModelId: String? = nil,
        approval: PaidEscalationApproval? = nil
    ) -> RoutingResolutionResult {
        let startTime = ContinuousClock.now

        // 1. Effective task kind (attachments force multimodal requirement)
        let effectiveKind = hasAttachments ? ModelTaskKind.multimodal : taskKind

        // 2. Check Space rule or global rule
        let rule = lookupRule(for: effectiveKind, spaceId: spaceId)
        let requestedModelId = preferredModelId ?? rule?.preferredModelId

        lock.lock()
        let catalog = self.models
        let limitHits = self.dailyLimitHits
        lock.unlock()

        // 3. If explicit model requested, evaluate it
        if let reqId = requestedModelId, let target = catalog[reqId] {
            if !target.isFree {
                // Paid model requested: gated escalation check
                let approved = approval?.isApproved ?? rule?.allowPaidEscalation ?? false
                if !approved {
                    let costNote = "Estimated cost $\(String(format: "%.4f", target.estimatedCostPer1kTokens))/1k tokens for '\(target.displayName)'."
                    Self.logger.warning("Paid escalation to '\(target.displayName, privacy: .public)' refused without explicit user approval.")
                    return .paidEscalationRefused(
                        reason: "Paid model '\(target.displayName)' requested but user approval was not granted. Refusing paid escalation to protect zero-spend guarantee.",
                        costNote: costNote
                    )
                }
            }

            // Check if requested model hit limit
            if let reason = limitHits[target.id] {
                // Advance to next capable free model
                return resolveFallback(
                    taskKind: effectiveKind,
                    spaceId: spaceId,
                    exhaustedModel: target,
                    exhaustedReason: reason,
                    startTime: startTime,
                    catalog: catalog,
                    limitHits: limitHits
                )
            }

            // Target is valid and operational
            let latencyMs = elapsedMs(since: startTime)
            let decision = RoutingDecision(
                spaceId: spaceId,
                taskKind: effectiveKind,
                selectedModelId: target.id,
                selectedProvider: target.provider,
                reason: "Preferred model selected: \(target.displayName)",
                isFree: target.isFree,
                estimatedCost: target.isFree ? 0.0 : target.estimatedCostPer1kTokens,
                latencyMs: latencyMs,
                fallbackNotice: nil
            )
            logDecision(decision)
            return .routed(decision: decision)
        }

        // 4. Default: Find cheapest capable free model for task
        let capableModels = catalog.values.filter { model in
            model.supportedTasks.contains(effectiveKind)
        }

        // Candidate ordering: Free models first, priority ascending, local first, then cost ascending
        let sortedCandidates = capableModels.sorted { (m1, m2) -> Bool in
            if m1.isFree != m2.isFree {
                return m1.isFree && !m2.isFree
            }
            let p1 = candidatePriority(model: m1, taskKind: effectiveKind)
            let p2 = candidatePriority(model: m2, taskKind: effectiveKind)
            if p1 != p2 {
                return p1 < p2
            }
            if m1.isLocal != m2.isLocal {
                return m1.isLocal && !m2.isLocal
            }
            if m1.estimatedCostPer1kTokens != m2.estimatedCostPer1kTokens {
                return m1.estimatedCostPer1kTokens < m2.estimatedCostPer1kTokens
            }
            return m1.id < m2.id
        }

        var attemptedExhausted: [(RoutableModel, String)] = []

        for candidate in sortedCandidates {
            // Free tier withdrawal check (integrates with FreeTierModelManager #118)
            if FreeTierModelManager.shared.isWithdrawn(provider: candidate.provider) {
                let reason = FreeTierModelManager.shared.withdrawalReason(provider: candidate.provider) ?? "Provider free-tier withdrawn"
                attemptedExhausted.append((candidate, reason))
                continue
            }

            // Daily limit check
            if let reason = limitHits[candidate.id] {
                attemptedExhausted.append((candidate, reason))
                continue
            }

            // Gated check if candidate is paid
            if !candidate.isFree {
                let approved = approval?.isApproved ?? rule?.allowPaidEscalation ?? false
                if !approved {
                    continue // Skip paid candidates on default path
                }
            }

            // Found capable candidate!
            let latencyMs = elapsedMs(since: startTime)
            var fallbackNotice: String? = nil
            var reasonMsg = "Cheapest capable model selected for \(effectiveKind.rawValue): \(candidate.displayName)"

            if let (exhaustedModel, limitReason) = attemptedExhausted.first {
                fallbackNotice = "⚠️ Model '\(exhaustedModel.displayName)' [\(exhaustedModel.id)] hit daily limit (\(limitReason)). Automatically falling back to '\(candidate.displayName)'. Remaining free-tier operation maintained."
                reasonMsg = "Fallback from \(exhaustedModel.displayName) (\(limitReason)) to \(candidate.displayName)"
            }

            let decision = RoutingDecision(
                spaceId: spaceId,
                taskKind: effectiveKind,
                selectedModelId: candidate.id,
                selectedProvider: candidate.provider,
                reason: reasonMsg,
                isFree: candidate.isFree,
                estimatedCost: candidate.isFree ? 0.0 : candidate.estimatedCostPer1kTokens,
                latencyMs: latencyMs,
                fallbackNotice: fallbackNotice
            )
            logDecision(decision)
            return .routed(decision: decision)
        }

        // All free models exhausted without fallback
        if let (exhaustedModel, limitReason) = attemptedExhausted.first {
            return .fallbackExhausted(reason: "All capable free-tier models for '\(effectiveKind.rawValue)' exhausted (initial: \(exhaustedModel.displayName), reason: \(limitReason)). Paid escalation is disallowed.")
        }

        return .fallbackExhausted(reason: "No capable model found for task kind '\(effectiveKind.rawValue)'")
    }

    private func resolveFallback(
        taskKind: ModelTaskKind,
        spaceId: UUID?,
        exhaustedModel: RoutableModel,
        exhaustedReason: String,
        startTime: ContinuousClock.Instant,
        catalog: [String: RoutableModel],
        limitHits: [String: String]
    ) -> RoutingResolutionResult {
        // Bounded fallback: strictly select next capable free model, excluding exhaustedModel and limitHits
        let candidates = catalog.values.filter { model in
            model.id != exhaustedModel.id &&
            model.supportedTasks.contains(taskKind) &&
            model.isFree &&
            limitHits[model.id] == nil &&
            !FreeTierModelManager.shared.isWithdrawn(provider: model.provider)
        }.sorted { (m1, m2) -> Bool in
            let p1 = candidatePriority(model: m1, taskKind: taskKind)
            let p2 = candidatePriority(model: m2, taskKind: taskKind)
            if p1 != p2 {
                return p1 < p2
            }
            if m1.isLocal != m2.isLocal { return m1.isLocal && !m2.isLocal }
            if m1.estimatedCostPer1kTokens != m2.estimatedCostPer1kTokens {
                return m1.estimatedCostPer1kTokens < m2.estimatedCostPer1kTokens
            }
            return m1.id < m2.id
        }

        guard let fallback = candidates.first else {
            return .fallbackExhausted(
                reason: "Exhausted fallback chain for '\(taskKind.rawValue)': '\(exhaustedModel.displayName)' failed (\(exhaustedReason)) and no alternate capable free model is available."
            )
        }

        let latencyMs = elapsedMs(since: startTime)
        let notice = "⚠️ Model '\(exhaustedModel.displayName)' [\(exhaustedModel.id)] hit daily limit (\(exhaustedReason)). Automatically falling back to '\(fallback.displayName)'. Remaining free-tier operation maintained."

        let decision = RoutingDecision(
            spaceId: spaceId,
            taskKind: taskKind,
            selectedModelId: fallback.id,
            selectedProvider: fallback.provider,
            reason: "Fallback on limit from \(exhaustedModel.displayName) to \(fallback.displayName)",
            isFree: true,
            estimatedCost: 0.0,
            latencyMs: latencyMs,
            fallbackNotice: notice
        )
        logDecision(decision)
        return .routed(decision: decision)
    }

    private func lookupRule(for taskKind: ModelTaskKind, spaceId: UUID?) -> TaskRoutingRule? {
        lock.lock()
        defer { lock.unlock() }

        if let sid = spaceId {
            let key = "\(sid.uuidString):\(taskKind.rawValue)"
            if let rule = rulesMap[key] {
                return rule
            }
        }
        let globalKey = "global:\(taskKind.rawValue)"
        return rulesMap[globalKey]
    }

    // MARK: - Logging & Observability

    private func logDecision(_ decision: RoutingDecision) {
        lock.lock()
        decisions.append(decision)
        if decisions.count > 500 {
            decisions.removeFirst(decisions.count - 500)
        }
        lock.unlock()

        Self.logger.info("Routing decision: [\(decision.taskKind.rawValue, privacy: .public)] -> [\(decision.selectedModelId, privacy: .public)] (cost: $\(decision.estimatedCost, format: .fixed(precision: 4)), latency: \(decision.latencyMs, format: .fixed(precision: 1))ms)")

        // Emit trace event for #112 / #110 trace integration
        RunTraceManager.shared.recordModelCall(
            model: decision.selectedModelId,
            prompt: "taskKind: \(decision.taskKind.rawValue)",
            tokenCounts: nil,
            durationMs: decision.latencyMs
        )
    }

    public func recentDecisions() -> [RoutingDecision] {
        lock.lock()
        defer { lock.unlock() }
        return decisions
    }

    public func clearDecisions() {
        lock.lock()
        defer { lock.unlock() }
        decisions.removeAll()
    }

    public func formattedLog() -> String {
        let decs = recentDecisions()
        guard !decs.isEmpty else { return "No routing decisions logged." }
        var lines: [String] = []
        lines.append("Timestamp | Task | Selected Model | Cost | Latency | Notice")
        lines.append("---|---|---|---|---|---")
        let formatter = ISO8601DateFormatter()
        for d in decs {
            let ts = formatter.string(from: d.timestamp)
            let notice = d.fallbackNotice ?? "-"
            lines.append("\(ts) | \(d.taskKind.rawValue) | \(d.selectedModelId) | $\(String(format: "%.4f", d.estimatedCost)) | \(String(format: "%.1f", d.latencyMs))ms | \(notice)")
        }
        return lines.joined(separator: "\n")
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let durationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return max(durationSeconds * 1000.0, 0.1)
    }
}
