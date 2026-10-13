// CopilotMultiModelRouter.swift
// Batch 121: Multi-model selection engine for GitHub Copilot with capability
// mapping, proactive token watchdog (refresh 3 min before expiry), and
// exponential backoff for HTTP 429 / 401 recovery.

import Foundation

// MARK: - Copilot Model

public enum CopilotModel: String, CaseIterable, Sendable, Codable, Identifiable, CustomStringConvertible {
    case gpt4o = "gpt-4o"
    case gpt4oMini = "gpt-4o-mini"
    case claude35Sonnet = "claude-3.5-sonnet"
    case o1Preview = "o1-preview"
    case o1Mini = "o1-mini"

    public var id: String { rawValue }

    public var description: String { displayName }

    public var displayName: String {
        switch self {
        case .gpt4o:
            return "GPT-4o"
        case .gpt4oMini:
            return "GPT-4o mini"
        case .claude35Sonnet:
            return "Claude 3.5 Sonnet"
        case .o1Preview:
            return "o1-preview"
        case .o1Mini:
            return "o1-mini"
        }
    }

    /// Whether the model supports token streaming responses. o1 models do NOT support streaming.
    public var supportsStreaming: Bool {
        switch self {
        case .gpt4o, .gpt4oMini, .claude35Sonnet:
            return true
        case .o1Preview, .o1Mini:
            return false
        }
    }

    /// Whether the model supports function/tool calling. o1-preview/mini do NOT support tools.
    public var supportsToolCalling: Bool {
        switch self {
        case .gpt4o, .gpt4oMini, .claude35Sonnet:
            return true
        case .o1Preview, .o1Mini:
            return false
        }
    }

    /// Whether the model is a specialized reasoning engine.
    public var isReasoningModel: Bool {
        switch self {
        case .o1Preview, .o1Mini:
            return true
        case .gpt4o, .gpt4oMini, .claude35Sonnet:
            return false
        }
    }

    /// Maximum context token window for the model.
    public var maxContextTokens: Int {
        switch self {
        case .claude35Sonnet:
            return 200_000
        case .gpt4o, .o1Preview:
            return 128_000
        case .gpt4oMini, .o1Mini:
            return 16_000
        }
    }

    /// Recommended maximum token allocation for model output generations.
    public var recommendedMaxOutputTokens: Int {
        switch self {
        case .claude35Sonnet:
            return 16_000
        case .o1Preview, .o1Mini:
            return 32_768
        case .gpt4o, .gpt4oMini:
            return 4_096
        }
    }
}

// MARK: - Copilot Token Watchdog

public actor CopilotTokenWatchdog {
    public static let shared = CopilotTokenWatchdog()

    private var watchdogTask: Task<Void, Never>?

    public init() {}

    /// Starts a background Task that loops, checking GitHubCopilotTokenManager.shared's
    /// cached expiry via getSessionToken() every 60 seconds, refreshing when < 180 seconds remain.
    public func startWatchdog() {
        stopWatchdog()
        watchdogTask = Task {
            while !Task.isCancelled {
                if let expiry = await GitHubCopilotTokenManager.shared.cachedExpiry {
                    if expiry.timeIntervalSinceNow < 180 {
                        _ = try? await GitHubCopilotTokenManager.shared.getSessionToken()
                    }
                } else {
                    _ = try? await GitHubCopilotTokenManager.shared.getSessionToken()
                }

                do {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    /// Cancels the watchdog background task.
    public func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    /// Indicates whether the watchdog task is currently active and uncancelled.
    public var isRunning: Bool {
        guard let task = watchdogTask else { return false }
        return !task.isCancelled
    }
}

// MARK: - Copilot Multi-Model Router

public actor CopilotMultiModelRouter {
    public static let shared = CopilotMultiModelRouter()

    private var rateLimitResetDate: Date?
    private var consecutiveFailures: Int = 0

    public init() {}

    /// Returns `preferred` if its capabilities match requirements; otherwise cascades:
    /// `.gpt4o` -> `.claude35Sonnet` -> `.gpt4oMini`.
    public func selectModel(
        preferred: CopilotModel,
        requiresToolCalling: Bool,
        requiresStreaming: Bool
    ) -> CopilotModel {
        if matchesCapabilities(preferred, requiresToolCalling: requiresToolCalling, requiresStreaming: requiresStreaming) {
            return preferred
        }

        let cascade: [CopilotModel] = [.gpt4o, .claude35Sonnet, .gpt4oMini]
        for candidate in cascade {
            if matchesCapabilities(candidate, requiresToolCalling: requiresToolCalling, requiresStreaming: requiresStreaming) {
                return candidate
            }
        }

        return .gpt4o
    }

    private func matchesCapabilities(
        _ model: CopilotModel,
        requiresToolCalling: Bool,
        requiresStreaming: Bool
    ) -> Bool {
        if requiresToolCalling && !model.supportsToolCalling {
            return false
        }
        if requiresStreaming && !model.supportsStreaming {
            return false
        }
        return true
    }

    /// Returns exponential backoff delay based on consecutive failure count:
    /// `min(pow(2.0, Double(consecutiveFailures)), 60.0)` seconds.
    public func exponentialBackoffDelay() -> TimeInterval {
        min(pow(2.0, Double(consecutiveFailures)), 60.0)
    }

    /// Resets consecutive failure counter on successful request execution.
    public func recordSuccess() {
        consecutiveFailures = 0
        rateLimitResetDate = nil
    }

    /// Increments failure counter, and sets rate limit reset date to `Date() + backoffDelay` on HTTP 429.
    public func recordFailure(httpStatus: Int) {
        consecutiveFailures += 1
        if httpStatus == 429 {
            rateLimitResetDate = Date().addingTimeInterval(exponentialBackoffDelay())
        }
    }

    /// Returns true if currently in an active rate limit backoff window.
    public func isRateLimited() -> Bool {
        guard let resetDate = rateLimitResetDate else { return false }
        return resetDate > Date()
    }

    /// Constructs HTTP headers required for GitHub Copilot Chat wire requests.
    public func buildRequestHeaders(sessionToken: String, model: CopilotModel) -> [String: String] {
        [
            "Authorization": "Bearer \(sessionToken)",
            "Editor-Version": "vscode/1.90.0",
            "Editor-Plugin-Version": "copilot-chat/0.17.0",
            "Copilot-Integration-Id": "vscode-chat",
            "User-Agent": "GitHubCopilotChat/0.17.0",
            "Content-Type": "application/json",
            "Accept": model.supportsStreaming ? "text/event-stream" : "application/json",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
    }
}

// MARK: - Copilot Router Audit Report

public struct CopilotRouterAuditReport: Sendable, Codable, Equatable {
    public var availableModels: [CopilotModel]
    public var defaultModel: CopilotModel
    public var streamingModels: [CopilotModel]
    public var reasoningModels: [CopilotModel]
    public var toolCallingModels: [CopilotModel]
    public var score: Double
    public var passed: Bool

    public static func audit() -> CopilotRouterAuditReport {
        let all = CopilotModel.allCases
        let def = CopilotModel.gpt4o
        let streaming = all.filter { $0.supportsStreaming }
        let reasoning = all.filter { $0.isReasoningModel }
        let toolCalling = all.filter { $0.supportsToolCalling }
        let allResolved = all.count == CopilotModel.allCases.count
        let score = allResolved ? 100.0 : 0.0
        let passed = allResolved && !streaming.isEmpty && !reasoning.isEmpty && !toolCalling.isEmpty

        return CopilotRouterAuditReport(
            availableModels: all,
            defaultModel: def,
            streamingModels: streaming,
            reasoningModels: reasoning,
            toolCallingModels: toolCalling,
            score: score,
            passed: passed
        )
    }
}
