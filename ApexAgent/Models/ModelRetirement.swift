//
//  ModelRetirement.swift
//  ApexAgent
//
//  Issue #180: Model retirement handling: auto-swap, warn, and keep working when a model disappears.
//

import Foundation
import os

// MARK: - Model Retirement Error

public enum ModelRetirementError: LocalizedError, Sendable, Equatable {
    case cannotRevertToRetiredModel(modelId: String, reason: String)
    case swapNotFound(id: UUID)
    case modelNotAvailable(modelId: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotRevertToRetiredModel(let modelId, let reason):
            return "Cannot revert to model '\(modelId)': the model has been retired (\(reason))."
        case .swapNotFound(let id):
            return "Model swap record with ID \(id) was not found."
        case .modelNotAvailable(let modelId, let reason):
            return "Model '\(modelId)' is not available: \(reason)."
        }
    }
}

// MARK: - Model Retirement Record

/// Metadata defining a model retirement schedule or active retirement event.
public struct ModelRetirementRecord: Identifiable, Sendable, Codable, Equatable {
    public var id: String { modelId }
    public let modelId: String
    public let displayName: String
    public let retirementDate: Date
    public let reason: String
    public let suggestedReplacementId: String?

    public init(
        modelId: String,
        displayName: String,
        retirementDate: Date,
        reason: String,
        suggestedReplacementId: String? = nil
    ) {
        self.modelId = modelId
        self.displayName = displayName
        self.retirementDate = retirementDate
        self.reason = reason
        self.suggestedReplacementId = suggestedReplacementId
    }

    public func isRetired(asOf date: Date = Date()) -> Bool {
        date >= retirementDate
    }
}

// MARK: - Per-Space Model Swap Record

/// Historical record of a model transition for an individual Space.
public struct SpaceModelSwapRecord: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let spaceId: UUID
    public let oldModelId: String
    public let newModelId: String
    public let reason: String
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        spaceId: UUID,
        oldModelId: String,
        newModelId: String,
        reason: String,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.spaceId = spaceId
        self.oldModelId = oldModelId
        self.newModelId = newModelId
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Model Retirement Notice

/// User-visible notification emitted when a model is retired, auto-swapped, or degraded.
public struct ModelRetirementNotice: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let spaceId: UUID?
    public let oldModelId: String
    public let newModelId: String?
    public let reason: String
    public let message: String
    public let offeredPaidOption: String?
    public let isGracefulDegradation: Bool

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        spaceId: UUID? = nil,
        oldModelId: String,
        newModelId: String?,
        reason: String,
        message: String,
        offeredPaidOption: String? = nil,
        isGracefulDegradation: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.spaceId = spaceId
        self.oldModelId = oldModelId
        self.newModelId = newModelId
        self.reason = reason
        self.message = message
        self.offeredPaidOption = offeredPaidOption
        self.isGracefulDegradation = isGracefulDegradation
    }
}

// MARK: - Model Retirement Manager

/// Central coordinator for model retirement registry, detection at startup and runtime,
/// auto-swap execution, graceful degradation notices, and per-Space swap histories.
public final class ModelRetirementManager: @unchecked Sendable {
    public static let shared = ModelRetirementManager()

    private static let logger = Logger(subsystem: "com.apexagent.ApexAgent", category: "ModelRetirement")

    private let lock = NSLock()

    // Retired model records keyed by modelId
    private var retirementRegistry: [String: ModelRetirementRecord] = [:]

    // Per-space swap history keyed by spaceId
    private var perSpaceHistory: [UUID: [SpaceModelSwapRecord]] = [:]

    // Visible notices log
    private var noticesList: [ModelRetirementNotice] = []

    public init() {
        registerDefaultRetirements()
    }

    // MARK: - Default Known Retirements

    public func registerDefaultRetirements() {
        lock.lock()
        defer { lock.unlock() }

        // GitHub Copilot models scheduled for retirement Dec 14, 2026
        let copilotGpt4Retirement = ModelRetirementRecord(
            modelId: "copilot-gpt-4-0613",
            displayName: "GitHub Copilot GPT-4 (0613)",
            retirementDate: ISO8601DateFormatter().date(from: "2026-12-14T00:00:00Z") ?? Date(timeIntervalSince1970: 1797206400),
            reason: "GitHub Copilot model version 0613 retired on Dec 14, 2026",
            suggestedReplacementId: "localOllama"
        )
        let copilotHaikuRetirement = ModelRetirementRecord(
            modelId: "copilot-claude-3-haiku",
            displayName: "GitHub Copilot Claude 3 Haiku",
            retirementDate: ISO8601DateFormatter().date(from: "2026-12-14T00:00:00Z") ?? Date(timeIntervalSince1970: 1797206400),
            reason: "GitHub Copilot Claude 3 Haiku retired on Dec 14, 2026",
            suggestedReplacementId: "appleOnDevice"
        )

        // Gemini Argon / legacy retirements
        let geminiArgonRetirement = ModelRetirementRecord(
            modelId: "gemini-argon",
            displayName: "Gemini Argon (Preview)",
            retirementDate: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z") ?? Date(timeIntervalSince1970: 1780272000),
            reason: "Gemini Argon preview endpoint shut down",
            suggestedReplacementId: "cloudGemini"
        )
        let gemini31ProPreviewRetirement = ModelRetirementRecord(
            modelId: "gemini-3.1-pro-preview",
            displayName: "Gemini 3.1 Pro Preview",
            retirementDate: ISO8601DateFormatter().date(from: "2026-08-15T00:00:00Z") ?? Date(timeIntervalSince1970: 1786752000),
            reason: "Gemini 3.1 Pro preview version retired",
            suggestedReplacementId: "cloudGemini"
        )
        let gemini10ProRetirement = ModelRetirementRecord(
            modelId: "gemini-1.0-pro",
            displayName: "Google Gemini 1.0 Pro",
            retirementDate: ISO8601DateFormatter().date(from: "2025-02-15T00:00:00Z") ?? Date(timeIntervalSince1970: 1739577600),
            reason: "Google Gemini 1.0 Pro deprecated by provider",
            suggestedReplacementId: "cloudGemini"
        )

        retirementRegistry[copilotGpt4Retirement.modelId] = copilotGpt4Retirement
        retirementRegistry[copilotHaikuRetirement.modelId] = copilotHaikuRetirement
        retirementRegistry[geminiArgonRetirement.modelId] = geminiArgonRetirement
        retirementRegistry[gemini31ProPreviewRetirement.modelId] = gemini31ProPreviewRetirement
        retirementRegistry[gemini10ProRetirement.modelId] = gemini10ProRetirement
    }

    // MARK: - Registry Operations

    public func registerRetirement(_ record: ModelRetirementRecord) {
        lock.lock()
        retirementRegistry[record.modelId] = record
        lock.unlock()
        Self.logger.info("Registered model retirement: [\(record.modelId, privacy: .public)] retiring \(record.retirementDate)")
    }

    public func unregisterRetirement(modelId: String) {
        lock.lock()
        retirementRegistry.removeValue(forKey: modelId)
        lock.unlock()
    }

    public func clearRetirements() {
        lock.lock()
        retirementRegistry.removeAll()
        lock.unlock()
    }

    public func resetToDefaults() {
        clearRetirements()
        registerDefaultRetirements()
    }

    public func isRetired(modelId: String, asOf date: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let record = retirementRegistry[modelId] else { return false }
        return record.isRetired(asOf: date)
    }

    public func retirementRecord(for modelId: String, asOf date: Date = Date()) -> ModelRetirementRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard let record = retirementRegistry[modelId] else { return nil }
        return record.isRetired(asOf: date) ? record : nil
    }

    public func allRetirements() -> [ModelRetirementRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(retirementRegistry.values)
    }

    // MARK: - Per-Space History Management

    public func recordSwap(
        spaceId: UUID,
        oldModelId: String,
        newModelId: String,
        reason: String,
        timestamp: Date = Date()
    ) {
        lock.lock()
        let swap = SpaceModelSwapRecord(
            spaceId: spaceId,
            oldModelId: oldModelId,
            newModelId: newModelId,
            reason: reason,
            timestamp: timestamp
        )
        var list = perSpaceHistory[spaceId] ?? []
        list.append(swap)
        perSpaceHistory[spaceId] = list
        lock.unlock()

        Self.logger.notice("Recorded model swap for Space [\(spaceId.uuidString.prefix(8), privacy: .public)]: '\(oldModelId, privacy: .public)' -> '\(newModelId, privacy: .public)' (\(reason, privacy: .public))")
    }

    public func history(for spaceId: UUID) -> [SpaceModelSwapRecord] {
        lock.lock()
        defer { lock.unlock() }
        return perSpaceHistory[spaceId] ?? []
    }

    public func clearHistory(for spaceId: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let sid = spaceId {
            perSpaceHistory.removeValue(forKey: sid)
        } else {
            perSpaceHistory.removeAll()
        }
    }

    public func canRevert(swapId: UUID, in spaceId: UUID) -> Bool {
        lock.lock()
        let swaps = perSpaceHistory[spaceId] ?? []
        lock.unlock()

        guard let swap = swaps.first(where: { $0.id == swapId }) else { return false }
        return !isRetired(modelId: swap.oldModelId)
    }

    /// Reverts a Space to a previous model from history if that model is still operational.
    /// Fails with `ModelRetirementError.cannotRevertToRetiredModel` if the model is retired.
    public func revert(
        swapId: UUID,
        in spaceId: UUID,
        router: ModelRouter = ModelRouter.shared
    ) throws -> String {
        lock.lock()
        let swaps = perSpaceHistory[spaceId] ?? []
        lock.unlock()

        guard let swap = swaps.first(where: { $0.id == swapId }) else {
            throw ModelRetirementError.swapNotFound(id: swapId)
        }

        if let rec = retirementRecord(for: swap.oldModelId) {
            throw ModelRetirementError.cannotRevertToRetiredModel(modelId: swap.oldModelId, reason: rec.reason)
        }

        // Apply revert rule to ModelRouter
        for kind in ModelTaskKind.allCases {
            let existingRules = router.rules(for: spaceId)
            let currentRule = existingRules.first(where: { $0.taskKind == kind })
            var updatedRule = currentRule ?? TaskRoutingRule(spaceId: spaceId, taskKind: kind)
            updatedRule.preferredModelId = swap.oldModelId
            router.setRule(updatedRule, for: spaceId)
        }

        // Record the revert action in swap history
        recordSwap(
            spaceId: spaceId,
            oldModelId: swap.newModelId,
            newModelId: swap.oldModelId,
            reason: "User reverted to previously configured model '\(swap.oldModelId)'"
        )

        return "Successfully reverted Space to '\(swap.oldModelId)'."
    }

    // MARK: - Notices Log

    public func recordNotice(_ notice: ModelRetirementNotice) {
        lock.lock()
        noticesList.append(notice)
        if noticesList.count > 500 {
            noticesList.removeFirst(noticesList.count - 500)
        }
        lock.unlock()
    }

    public func notices(for spaceId: UUID? = nil) -> [ModelRetirementNotice] {
        lock.lock()
        defer { lock.unlock() }
        if let sid = spaceId {
            return noticesList.filter { $0.spaceId == sid }
        }
        return noticesList
    }

    public func clearNotices() {
        lock.lock()
        noticesList.removeAll()
        lock.unlock()
    }

    // MARK: - Startup & Runtime Detection Engine

    /// Scans provided spaceIds (or all known rules) for any model pointing to a retired model.
    /// Auto-swaps them immediately to the nearest capable free replacement, emits visible notices,
    /// and records the swap in per-Space history so no Space is left pointing at a dead model.
    @discardableResult
    public func detectAndSwap(
        spaceIds: [UUID],
        router: ModelRouter = ModelRouter.shared,
        atStartup: Bool = false
    ) -> [ModelRetirementNotice] {
        var generatedNotices: [ModelRetirementNotice] = []
        let phase = atStartup ? "startup" : "runtime"

        for spaceId in spaceIds {
            let rules = router.rules(for: spaceId)
            for rule in rules {
                guard let prefModelId = rule.preferredModelId else { continue }
                if let record = retirementRecord(for: prefModelId) {
                    Self.logger.warning("Detected retired model [\(prefModelId, privacy: .public)] in Space [\(spaceId.uuidString.prefix(8), privacy: .public)] during \(phase, privacy: .public). Executing auto-swap.")

                    // Find nearest capable free replacement
                    let replacement = findNearestFreeReplacement(for: rule.taskKind, excluding: prefModelId, router: router)

                    if let rep = replacement {
                        // Update Space rule immediately
                        var updatedRule = rule
                        updatedRule.preferredModelId = rep.id
                        router.setRule(updatedRule, for: spaceId)

                        // Record swap in per-space history
                        let swapReason = "Retired (\(record.reason)) during \(phase) inspection"
                        recordSwap(spaceId: spaceId, oldModelId: prefModelId, newModelId: rep.id, reason: swapReason)

                        let notice = ModelRetirementNotice(
                            spaceId: spaceId,
                            oldModelId: prefModelId,
                            newModelId: rep.id,
                            reason: record.reason,
                            message: "⚠️ Model '\(record.displayName)' [\(prefModelId)] is retired (\(record.reason)). Automatically swapped to nearest capable free replacement '\(rep.displayName)' [\(rep.id)].",
                            offeredPaidOption: nil,
                            isGracefulDegradation: false
                        )
                        recordNotice(notice)
                        generatedNotices.append(notice)
                    } else {
                        // Graceful degradation when no free replacement exists
                        let cheapestPaid = findCheapestPaidOption(for: rule.taskKind, router: router)
                        let paidNote = cheapestPaid != nil ?
                            "Cheapest available option: '\(cheapestPaid!.displayName)' ($\(String(format: "%.4f", cheapestPaid!.estimatedCostPer1kTokens))/1k tokens)." :
                            nil

                        let notice = ModelRetirementNotice(
                            spaceId: spaceId,
                            oldModelId: prefModelId,
                            newModelId: nil,
                            reason: record.reason,
                            message: "⚠️ Model '\(record.displayName)' [\(prefModelId)] is retired (\(record.reason)). No capable free replacement exists for '\(rule.taskKind.rawValue)'. Next cheapest option offered: \(paidNote ?? "None"). Zero spend guarantee: no paid model was selected.",
                            offeredPaidOption: paidNote,
                            isGracefulDegradation: true
                        )
                        recordNotice(notice)
                        generatedNotices.append(notice)
                    }
                }
            }
        }

        return generatedNotices
    }

    /// Finds the nearest capable free replacement for a task kind, excluding retired models.
    public func findNearestFreeReplacement(
        for taskKind: ModelTaskKind,
        excluding excludedModelId: String,
        router: ModelRouter = ModelRouter.shared
    ) -> RoutableModel? {
        let catalog = router.allModels()
        let freeCandidates = catalog.filter { model in
            model.id != excludedModelId &&
            model.supportedTasks.contains(taskKind) &&
            model.isFree &&
            !isRetired(modelId: model.id) &&
            !router.isDailyLimitHit(modelId: model.id) &&
            !FreeTierModelManager.shared.isWithdrawn(provider: model.provider)
        }.sorted { (m1, m2) -> Bool in
            let p1 = router.candidatePriority(model: m1, taskKind: taskKind)
            let p2 = router.candidatePriority(model: m2, taskKind: taskKind)
            if p1 != p2 { return p1 < p2 }
            if m1.isLocal != m2.isLocal { return m1.isLocal && !m2.isLocal }
            if m1.estimatedCostPer1kTokens != m2.estimatedCostPer1kTokens {
                return m1.estimatedCostPer1kTokens < m2.estimatedCostPer1kTokens
            }
            return m1.id < m2.id
        }

        return freeCandidates.first
    }

    /// Finds the cheapest available paid model for a task kind (for user choice, never auto-selected).
    public func findCheapestPaidOption(
        for taskKind: ModelTaskKind,
        router: ModelRouter = ModelRouter.shared
    ) -> RoutableModel? {
        let catalog = router.allModels()
        let paidCandidates = catalog.filter { model in
            !model.isFree &&
            model.supportedTasks.contains(taskKind) &&
            !isRetired(modelId: model.id)
        }.sorted { (m1, m2) -> Bool in
            if m1.estimatedCostPer1kTokens != m2.estimatedCostPer1kTokens {
                return m1.estimatedCostPer1kTokens < m2.estimatedCostPer1kTokens
            }
            return m1.id < m2.id
        }

        return paidCandidates.first
    }
}
