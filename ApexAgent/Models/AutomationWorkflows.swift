import Foundation
import SwiftData
import SharedKit

// MARK: - Automation Workflows
//
// Ten local automation workflows wired to ApexAgent's REAL code paths
// (tools, StateGraph, AgentRegistry, ProjectAuditor, SwiftData persistence).
// No third-party services, no network. Each workflow returns a WorkflowResult
// with a hard pass/fail verdict plus the evidence it verified.
//
// Run them with:  swift run apexflow            (all)
//                 swift run apexflow 3 7        (selected)

public struct WorkflowResult: Sendable {
    public let id: Int
    public let name: String
    public let passed: Bool
    public let evidence: String

    public init(id: Int, name: String, passed: Bool, evidence: String) {
        self.id = id
        self.name = name
        self.passed = passed
        self.evidence = evidence
    }

    public var line: String {
        "\(passed ? "PASS" : "FAIL") [\(id)] \(name) — \(evidence)"
    }
}

@MainActor
public enum ApexWorkflows {

    // MARK: Harness

    /// Builds an orchestrator wired to an in-memory SwiftData store with all
    /// folder permissions granted and confirmation auto-approved, so tool
    /// calls execute for real without UI prompts.
    static func makeOrchestrator(workspace: String) throws -> AgentOrchestrator {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([
            Conversation.self, Message.self, AgentMemory.self, AppPermissions.self,
            ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self,
            ReviewSession.self, WeeklyReflection.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        orchestrator.modelContext = ModelContext(container)

        let perms = AppPermissions()
        perms.musicFolderAllowed = true
        perms.desktopFolderAllowed = true
        perms.documentsFolderAllowed = true
        perms.downloadsFolderAllowed = true
        orchestrator.modelContext?.insert(perms)
        orchestrator.permissions = perms

        orchestrator.currentWorkspacePath = workspace
        orchestrator.confirmationGateway = { _, _, _ in true }

        let conversation = Conversation(title: "apexflow")
        orchestrator.modelContext?.insert(conversation)
        orchestrator.currentConversation = conversation
        return orchestrator
    }

    /// Scratch directory inside NSTemporaryDirectory (an allowed sandbox root).
    static func makeScratch(_ label: String) throws -> String {
        let dir = NSTemporaryDirectory() + "apexflow-\(label)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func run(ids: Set<Int>) async -> [WorkflowResult] {
        let all: [(Int, String, () async -> WorkflowResult)] = [
            (1, "AI-assisted code review + persisted findings", workflow1),
            (2, "Natural-language query over the project store", workflow2),
            (3, "Test generation + self-healing selector repair", workflow3),
            (4, "Documentation generation pipeline", workflow4),
            (5, "CI/CD failure triage agent", workflow5),
            (6, "Multi-agent task orchestration (StateGraph)", workflow6),
            (7, "Pipeline / schema-drift monitoring", workflow7),
            (8, "Ticket triage + routing", workflow8),
            (9, "Legacy refactor modernization sweep", workflow9),
            (10, "Personal productivity agent (briefing + standup)", workflow10),
        ]
        var results: [WorkflowResult] = []
        for (id, _, body) in all where ids.isEmpty || ids.contains(id) {
            results.append(await body())
        }
        return results
    }
}
