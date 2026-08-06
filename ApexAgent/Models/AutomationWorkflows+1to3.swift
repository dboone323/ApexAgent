import Foundation
import SwiftData
import SharedModels

// Workflows 1–3.
@MainActor
extension ApexWorkflows {

    // MARK: 1 — AI-assisted code review + persisted findings
    //
    // Real path: FileWriteTool → a deterministic Swift review pass →
    // SaveReviewSessionTool → ListReviewSessionsTool, all through the actual
    // tool `call(arguments:)` API and the real SwiftData ReviewSession model.
    static func workflow1() async -> WorkflowResult {
        let name = "AI-assisted code review + persisted findings"
        do {
            let scratch = try makeScratch("review")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            let target = scratch + "/PaymentProcessor.swift"
            let source = """
            import Foundation

            struct PaymentProcessor {
                let apiKey = "sk_live_HARDCODED_SECRET"

                func charge(_ amount: Double) -> String {
                    let receipt = try! makeReceipt(amount)
                    return receipt
                }

                func makeReceipt(_ amount: Double) throws -> String {
                    return "receipt-\\(amount)"
                }
            }
            """
            _ = try await FileWriteTool(orchestrator: orch)
                .call(arguments: .init(path: target, content: source, append: false))

            let read = try await FileReadTool(orchestrator: orch)
                .call(arguments: .init(path: target, maxLines: nil))
            let issues = CodeReviewRules.scan(read)
            guard issues.contains(where: { $0.severity == "error" }),
                  issues.contains(where: { $0.message.contains("try!") }) else {
                return WorkflowResult(id: 1, name: name, passed: false,
                                      evidence: "review pass did not detect seeded defects: \(issues)")
            }

            let issuesJSON = String(
                decoding: try JSONEncoder().encode(issues), as: UTF8.self)
            let saved = try await SaveReviewSessionTool(orchestrator: orch).call(
                arguments: .init(
                    fileName: "PaymentProcessor.swift",
                    summary: "Automated pre-review of payment module.",
                    suggestions: ["Move the API key to KeychainManager.",
                                  "Replace try! with a thrown error."],
                    issuesJSON: issuesJSON))
            guard saved.contains("SUCCESS") else {
                return WorkflowResult(id: 1, name: name, passed: false, evidence: saved)
            }

            let listed = try await ListReviewSessionsTool(orchestrator: orch)
                .call(arguments: .init())
            let persisted = listed.contains("PaymentProcessor.swift")
                && listed.contains("hardcoded")
            return WorkflowResult(
                id: 1, name: name, passed: persisted,
                evidence: persisted
                    ? "\(issues.count) issues detected and read back from ReviewSession store"
                    : "issues not readable from store: \(listed.prefix(200))")
        } catch {
            return WorkflowResult(id: 1, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }

    // MARK: 2 — Natural-language query over the project store
    //
    // The article's NL→SQL workflow, mapped to ApexAgent's actual datastore:
    // SwiftData, not SQL. Real path: CreateProjectTool / CreateTaskTool write
    // records, ProjectQueryPlanner translates plain English into a
    // FetchDescriptor-backed query executed by the real ListTasksTool.
    static func workflow2() async -> WorkflowResult {
        let name = "Natural-language query over the project store"
        do {
            let scratch = try makeScratch("query")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            let created = try await CreateProjectTool(orchestrator: orch).call(
                arguments: .init(name: "Apex Core", summary: "Agent runtime",
                                 language: "Swift", repoURL: nil, localPath: scratch))
            guard let projectID = try? orch.modelContext?
                .fetch(FetchDescriptor<ProjectModel>()).first?.id.uuidString else {
                return WorkflowResult(id: 2, name: name, passed: false, evidence: created)
            }

            let taskTool = CreateTaskTool(orchestrator: orch)
            for (title, priority) in [("Fix MCP timeout", "high"),
                                      ("Polish settings pane", "low"),
                                      ("Harden sandbox", "high")] {
                _ = try await taskTool.call(arguments: .init(
                    projectID: projectID, sprintID: nil, title: title,
                    detail: nil, priority: priority, estimatedHours: 2))
            }

            let question = "which high priority tasks are open on Apex Core?"
            let plan = ProjectQueryPlanner.plan(question)
            guard plan.priority == .high else {
                return WorkflowResult(id: 2, name: name, passed: false,
                                      evidence: "planner failed to extract priority from: \(question)")
            }
            let answer = try await plan.execute(orchestrator: orch)
            let ok = answer.contains("Fix MCP timeout")
                && answer.contains("Harden sandbox")
                && !answer.contains("Polish settings pane")
            return WorkflowResult(
                id: 2, name: name, passed: ok,
                evidence: ok
                    ? "NL question resolved to 2 high-priority tasks, low-priority correctly excluded"
                    : "unexpected answer: \(answer.prefix(200))")
        } catch {
            return WorkflowResult(id: 2, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }

    // MARK: 3 — Test generation + self-healing selector repair
    //
    // Generates a real Swift Testing file from a source file's public API,
    // then repairs an XCUITest whose accessibility identifier drifted —
    // the exact failure mode recorded in this repo's UI test history.
    static func workflow3() async -> WorkflowResult {
        let name = "Test generation + self-healing selector repair"
        do {
            let scratch = try makeScratch("tests")
            defer { try? FileManager.default.removeItem(atPath: scratch) }
            let orch = try makeOrchestrator(workspace: scratch)

            let subject = scratch + "/RetryPolicy.swift"
            _ = try await FileWriteTool(orchestrator: orch).call(arguments: .init(
                path: subject,
                content: """
                public struct RetryPolicy {
                    public func backoff(attempt: Int) -> Double { ... }
                    public func shouldRetry(status: Int) -> Bool { ... }
                }
                """,
                append: false))

            let read = try await FileReadTool(orchestrator: orch)
                .call(arguments: .init(path: subject, maxLines: nil))
            let generated = TestScaffolder.generateSuite(
                forSourceNamed: "RetryPolicy", source: read)
            let testPath = scratch + "/RetryPolicyTests.swift"
            _ = try await FileWriteTool(orchestrator: orch)
                .call(arguments: .init(path: testPath, content: generated, append: false))

            let wrote = try await FileReadTool(orchestrator: orch)
                .call(arguments: .init(path: testPath, maxLines: nil))
            guard wrote.contains("@Test func testBackoff"),
                  wrote.contains("@Test func testShouldRetry"),
                  wrote.contains("@Suite(\"RetryPolicyTests\")") else {
                return WorkflowResult(id: 3, name: name, passed: false,
                                      evidence: "scaffolder output missing cases: \(wrote.prefix(200))")
            }

            // Self-healing: identifier renamed in the app, stale in the test.
            let stale = #"app.buttons["SendButton"].tap()"#
            let liveIdentifiers = ["ComposerSendButton", "SidebarNewChatButton"]
            guard let healed = SelectorHealer.heal(stale, against: liveIdentifiers),
                  healed.contains("ComposerSendButton") else {
                return WorkflowResult(id: 3, name: name, passed: false,
                                      evidence: "selector healer did not repair SendButton")
            }
            let noFalsePositive = SelectorHealer.heal(
                #"app.buttons["ComposerSendButton"].tap()"#, against: liveIdentifiers) == nil
            return WorkflowResult(
                id: 3, name: name, passed: noFalsePositive,
                evidence: noFalsePositive
                    ? "2 tests generated; stale SendButton healed to ComposerSendButton; no rewrite when already valid"
                    : "healer rewrote an already-valid identifier")
        } catch {
            return WorkflowResult(id: 3, name: name, passed: false,
                                  evidence: "threw: \(error.localizedDescription)")
        }
    }
}
