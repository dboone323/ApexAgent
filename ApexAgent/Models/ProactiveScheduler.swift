import Foundation
import Observation
import UserNotifications
import AppKit

// MARK: - ProactiveScheduler: Autonomous Bot Proactivity Engine
//
// Automatically scans running operations for stalled delegations, pending confirmations
// approaching timeout, unhandled bot attention flags, and failed recurring routines.
// Proactively alerts the user or nudges assigned bots before work stalls.

@Observable
@MainActor
public final class ProactiveScheduler {
    public static let shared = ProactiveScheduler()

    public enum FindingSeverity: String, Codable, Sendable {
        case info
        case warning
        case critical
    }

    public struct ProactiveFinding: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let title: String
        public let detail: String
        public let severity: FindingSeverity
        public let targetBotName: String?

        public init(
            id: UUID = UUID(),
            timestamp: Date = Date(),
            title: String,
            detail: String,
            severity: FindingSeverity,
            targetBotName: String? = nil
        ) {
            self.id = id
            self.timestamp = timestamp
            self.title = title
            self.detail = detail
            self.severity = severity
            self.targetBotName = targetBotName
        }
    }

    public private(set) var isRunning: Bool = false
    public var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "apex.proactiveScheduler.enabled")
            if isEnabled && !isRunning {
                start()
            } else if !isEnabled && isRunning {
                stop()
            }
        }
    }

    public var checkIntervalSeconds: TimeInterval = 30.0
    public private(set) var lastCheckTime: Date?
    public private(set) var activeFindings: [ProactiveFinding] = []

    private var heartbeatTimer: Timer?
    weak var orchestrator: AgentOrchestrator?
    weak var botManager: BotManager?

    public init() {
        if UserDefaults.standard.object(forKey: "apex.proactiveScheduler.enabled") != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: "apex.proactiveScheduler.enabled")
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                _ = await self?.evaluateNow()
            }
        }
    }

    public func stop() {
        isRunning = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Evaluation

    @discardableResult
    public func evaluateNow() async -> [ProactiveFinding] {
        lastCheckTime = Date()
        var findings: [ProactiveFinding] = []

        // 1. Check for Pending High-Risk Tool Confirmations approaching stall
        if let orch = orchestrator, let confirmation = orch.pendingConfirmation {
            let finding = ProactiveFinding(
                title: "Pending Tool Confirmation Requires Attention",
                detail: "Tool '\(confirmation.toolName)' is awaiting authorization: \(confirmation.riskDescription)",
                severity: .critical,
                targetBotName: nil
            )
            findings.append(finding)
            notifyUser(title: finding.title, body: finding.detail)
        }

        // 2. Check for Bots Needing Attention
        if let bm = botManager {
            for bot in bm.allBots {
                let session = bm.session(for: bot)
                if session.needsAttention {
                    let finding = ProactiveFinding(
                        title: "Teammate Needs Attention",
                        detail: "Bot '\(bot.name)' has unresolved tasks or questions.",
                        severity: .warning,
                        targetBotName: bot.name
                    )
                    findings.append(finding)
                }
            }
        }

        // 3. Check for Stalled Handoffs in AgentRegistry
        let recentHandoffs = await AgentRegistry.shared.recentHandoffs()
        for handoff in recentHandoffs {
            if handoff.status == "in_progress" || handoff.status == "failed" {
                let finding = ProactiveFinding(
                    title: handoff.status == "failed" ? "Agent Task Failed" : "Agent Task In Progress",
                    detail: "Task '\(handoff.taskId)': \(handoff.errorDetails ?? handoff.resultSummary)",
                    severity: handoff.status == "failed" ? .critical : .warning,
                    targetBotName: nil
                )
                findings.append(finding)
            }
        }

        // 4. Background Dream Cycle Consolidation for Idle Bots
        if let bm = botManager {
            for bot in bm.allBots {
                if !bm.isGenerating(botId: bot.id) {
                    await CognitiveMemoryEngine.shared.runConsolidationCycle(forBotId: bot.id)
                }
            }
        }

        self.activeFindings = findings
        return findings
    }


    // MARK: - Finding Management & Markdown Formatting

    public func dismissFinding(id: UUID) {
        activeFindings.removeAll { $0.id == id }
    }

    public func clearAllFindings() {
        activeFindings.removeAll()
    }

    public func formatFindingsAsMarkdown() -> String {
        guard !activeFindings.isEmpty else {
            return "No active proactive findings. All agent operations are healthy."
        }

        var md = "### ⚡️ Proactive Scheduler System Health Findings\n\n"
        md += "| Severity | Title | Detail | Target Bot |\n"
        md += "|---|---|---|---|\n"

        for f in activeFindings {
            let sevBadge: String
            switch f.severity {
            case .critical: sevBadge = "🛑 Critical"
            case .warning: sevBadge = "⚠️ Warning"
            case .info: sevBadge = "ℹ️ Info"
            }
            let botText = f.targetBotName.map { "`@\($0)`" } ?? "System"
            md += "| \(sevBadge) | **\(f.title)** | \(f.detail) | \(botText) |\n"
        }
        return md
    }

    private func notifyUser(title: String, body: String) {
        let isTesting = getenv("APEX_TEST_MODE") != nil
            || ProcessInfo.processInfo.processName.localizedCaseInsensitiveContains("xctest")
            || NSClassFromString("XCTestCase") != nil
        if isTesting { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

extension ProactiveScheduler.ProactiveFinding {
    public func formatAsMarkdown() -> String {
        let badge: String
        switch severity {
        case .critical: badge = "🛑 Critical"
        case .warning: badge = "⚠️ Warning"
        case .info: badge = "ℹ️ Info"
        }
        var md = "### ⚡️ Proactive Finding: \(title)\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Severity | \(badge) |\n"
        md += "| Target Bot | `\(targetBotName ?? "system")` |\n"
        md += "| Detail | \(detail.prefix(300)) |\n"
        return md
    }
}
