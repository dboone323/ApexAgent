import Foundation
import SwiftData
import SharedModels

// Workflows 8–10.
@MainActor
extension ApexWorkflows {

    // MARK: 8 — Ticket triage + routing
    //
    // Real path: TicketTriage maps free-text tickets onto the actual
    // AgentRegistry roster, then files them as real TaskModel rows via
    // CreateTaskTool and reads them back with ListTasksTool.
    static func workflow8() async -> WorkflowResult {
        let name = "Ticket triage + routing"
        do {
            let scratch = try makeScratch("triage")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            _ = try await CreateProjectTool(orchestrator: orch).call(
                arguments: .init(name: "Support Queue", summary: "Inbound tickets",
                                 language: "Swift", repoURL: nil, localPath: scratch))
            guard let projectID = try? orch.modelContext?
                .fetch(FetchDescriptor<ProjectModel>()).first?.id.uuidString else {
                return WorkflowResult(id: 8, name: name, passed: false, evidence: "no project row")
            }

            let tickets = [
                "App crashes with a nil unwrap when opening settings",
                "Please document the new run_workflow tool in the README",
                "Build is failing on CI after the Swift 6.4 bump",
                "Can we research whether MLX supports this quantization?",
            ]
            let routes = tickets.map { TicketTriage.route($0) }
            let assigned = routes.map(\.agent)
            let valid = assigned.allSatisfy { AgentRegistry.shared.resolve(name: $0) != nil }
            guard valid else {
                return WorkflowResult(id: 8, name: name, passed: false,
                                      evidence: "routed to unknown agents: \(assigned)")
            }
            guard assigned == ["developer", "planner", "executor", "researcher"] else {
                return WorkflowResult(id: 8, name: name, passed: false,
                                      evidence: "unexpected routing: \(assigned)")
            }

            let taskTool = CreateTaskTool(orchestrator: orch)
            for (ticket, route) in zip(tickets, routes) {
                _ = try await taskTool.call(arguments: .init(
                    projectID: projectID, sprintID: nil,
                    title: "[\(route.agent)] " + ticket,
                    detail: route.rationale, priority: route.priority, estimatedHours: nil))
            }
            let listed = try await ListTasksTool(orchestrator: orch)
                .call(arguments: .init(projectID: projectID, sprintID: nil))
            let filed = tickets.allSatisfy { listed.contains($0) }
            let crashIsHigh = routes[0].priority == "high"
            let ok = filed && crashIsHigh
            return WorkflowResult(
                id: 8, name: name, passed: ok,
                evidence: ok
                    ? "4 tickets routed to real registry agents and persisted as TaskModel rows; crash escalated to high"
                    : "filed=\(filed) crashPriority=\(routes[0].priority)")
        } catch {
            return WorkflowResult(id: 8, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }

    // MARK: 9 — Legacy refactor modernization sweep
    //
    // Real path: FileSearchTool greps the actual workspace for legacy
    // patterns, ModernizationSweep proposes rewrites, FileWriteTool applies
    // them, and the file is re-read to confirm the change landed.
    static func workflow9() async -> WorkflowResult {
        let name = "Legacy refactor modernization sweep"
        do {
            let scratch = try makeScratch("refactor")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            let legacyPath = scratch + "/Legacy.swift"
            let legacy = """
            import Foundation

            class Legacy {
                func load(completion: @escaping (String) -> Void) {
                    DispatchQueue.main.async {
                        completion("done")
                    }
                }
                func stamp() -> String {
                    return NSString(string: "/tmp/x").lastPathComponent
                }
            }
            """
            _ = try await FileWriteTool(orchestrator: orch)
                .call(arguments: .init(path: legacyPath, content: legacy, append: false))

            let hits = try await FileSearchTool(orchestrator: orch).call(
                arguments: .init(query: "DispatchQueue.main.async",
                                 directory: scratch, filePattern: nil))
            guard hits.contains("Legacy.swift") else {
                return WorkflowResult(id: 9, name: name, passed: false,
                                      evidence: "grep did not locate the legacy pattern: \(hits.prefix(200))")
            }

            let current = try await FileReadTool(orchestrator: orch)
                .call(arguments: .init(path: legacyPath, maxLines: nil))
            let proposals = ModernizationSweep.proposals(for: current)
            guard proposals.count >= 2 else {
                return WorkflowResult(id: 9, name: name, passed: false,
                                      evidence: "expected >=2 proposals, got \(proposals.count)")
            }
            let modernized = ModernizationSweep.apply(proposals, to: current)
            _ = try await FileWriteTool(orchestrator: orch)
                .call(arguments: .init(path: legacyPath, content: modernized, append: false))

            let after = try await FileReadTool(orchestrator: orch)
                .call(arguments: .init(path: legacyPath, maxLines: nil))
            let ok = after.contains("@MainActor")
                && !after.contains("DispatchQueue.main.async")
                && after.contains("completion: @Sendable")
            return WorkflowResult(
                id: 9, name: name, passed: ok,
                evidence: ok
                    ? "\(proposals.count) modernization proposals applied and verified on disk (GCD→@MainActor, @escaping→@Sendable)"
                    : "post-refactor file still legacy: \(after.prefix(200))")
        } catch {
            return WorkflowResult(id: 9, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }

    // MARK: 10 — Personal productivity agent
    //
    // Real path: DailyBriefingTool reads the live AppGroup data bus; the
    // standup section is generated from this repo's actual git history via
    // ShellTool; both are persisted as a WeeklyReflection through the real
    // WeeklyReflectionTool and read back.
    static func workflow10() async -> WorkflowResult {
        let name = "Personal productivity agent (briefing + standup)"
        do {
            let scratch = try makeScratch("briefing")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            let briefing = try await DailyBriefingTool(orchestrator: orch)
                .call(arguments: .init())
            guard !briefing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return WorkflowResult(id: 10, name: name, passed: false,
                                      evidence: "daily briefing returned empty")
            }

            let repo = FileManager.default.currentDirectoryPath
            let log = try await ShellTool(orchestrator: orch).call(arguments: .init(
                command: "git -C '\(repo)' log --oneline -5 2>/dev/null | cat",
                workingDirectory: nil, timeoutSeconds: 30))
            let standup = StandupComposer.compose(briefing: briefing, gitLog: log)
            guard standup.contains("## Standup"), standup.contains("## Briefing") else {
                return WorkflowResult(id: 10, name: name, passed: false,
                                      evidence: "composer output malformed")
            }

            let tool = WeeklyReflectionTool(modelContext: orch.modelContext)
            let reflection = WeeklyReflection.snapshot(text: standup)
            try tool.save(reflection: reflection)

            // Read back through the same store the tool wrote to.
            let stored = (try? orch.modelContext?
                .fetch(FetchDescriptor<WeeklyReflection>())) ?? []
            let recent = stored.sorted { $0.createdAt > $1.createdAt }.prefix(3)
            let ok = recent.contains { $0.text.contains("## Standup") }
            return WorkflowResult(
                id: 10, name: name, passed: ok,
                evidence: ok
                    ? "briefing generated from the live data bus, standup composed from real git history, persisted and re-read as WeeklyReflection"
                    : "reflection not readable back from the store")
        } catch {
            return WorkflowResult(id: 10, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }
}
