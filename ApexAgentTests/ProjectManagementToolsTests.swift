import Testing
import Foundation
import SwiftData
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("ProjectManagementToolsTests") final class ProjectManagementToolsTests {
    private var orchestrator: AgentOrchestrator!
    private var container: ModelContainer!
    
    init() async throws {
        
        orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
    }
    
    private func makeArgs<T: Decodable>(_ json: String) -> T {
        let data = json.data(using: .utf8)!
        return try! JSONDecoder().decode(T.self, from: data)
    }
    
    @Test func testCreateProjectSprintAndTask() async throws {
        // 1. Test CreateProjectTool
        let createProj = CreateProjectTool(orchestrator: orchestrator)
        let projArgs: CreateProjectTool.Arguments = makeArgs("""
        {
            "name": "Audit Pipeline",
            "summary": "Automated compiler diagnostic checks",
            "language": "Swift",
            "localPath": "/tmp/pipeline"
        }
        """)
        let projResult = try await createProj.call(arguments: projArgs)
        #expect(projResult.contains("SUCCESS"))
        
        let projects = try orchestrator.modelContext?.fetch(FetchDescriptor<ProjectModel>()) ?? []
        #expect(projects.count == 1)
        #expect(projects.first?.name == "Audit Pipeline")
        let projectIDString = projects.first!.id.uuidString
        
        // 2. Test CreateSprintTool
        let createSprint = CreateSprintTool(orchestrator: orchestrator)
        let sprintArgs: CreateSprintTool.Arguments = makeArgs("""
        {
            "projectID": "\(projectIDString)",
            "name": "Sprint 1",
            "goal": "Fix strict concurrency",
            "startDateString": "2026-07-01",
            "endDateString": "2026-07-14"
        }
        """)
        let sprintResult = try await createSprint.call(arguments: sprintArgs)
        #expect(sprintResult.contains("SUCCESS"))
        
        let sprints = try orchestrator.modelContext?.fetch(FetchDescriptor<SprintModel>()) ?? []
        #expect(sprints.count == 1)
        #expect(sprints.first?.name == "Sprint 1")
        let sprintIDString = sprints.first!.id.uuidString
        
        // 3. Test CreateTaskTool
        let createTask = CreateTaskTool(orchestrator: orchestrator)
        let taskArgs: CreateTaskTool.Arguments = makeArgs("""
        {
            "projectID": "\(projectIDString)",
            "sprintID": "\(sprintIDString)",
            "title": "Fix task leaks",
            "detail": "Capture weak self in handlers",
            "priority": "High",
            "estimatedHours": 4.0
        }
        """)
        let taskResult = try await createTask.call(arguments: taskArgs)
        #expect(taskResult.contains("SUCCESS"))
        
        let tasks = try orchestrator.modelContext?.fetch(FetchDescriptor<TaskModel>()) ?? []
        #expect(tasks.count == 1)
        #expect(tasks.first?.title == "Fix task leaks")
        let taskIDString = tasks.first!.id.uuidString
        
        // 4. Test UpdateTaskStatusTool
        let updateStatus = UpdateTaskStatusTool(orchestrator: orchestrator)
        let updateArgs: UpdateTaskStatusTool.Arguments = makeArgs("""
        {
            "taskID": "\(taskIDString)",
            "status": "in_progress",
            "actualHours": 2.0
        }
        """)
        let updateResult = try await updateStatus.call(arguments: updateArgs)
        #expect(updateResult.contains("SUCCESS"))
        
        let updatedTasks = try orchestrator.modelContext?.fetch(FetchDescriptor<TaskModel>()) ?? []
        #expect(updatedTasks.first?.status == .inProgress)
    }
}
