import Foundation
import FoundationModels
import SwiftData
import SharedKit

// MARK: - Create Project Tool
struct CreateProjectTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "create_project"
    let description = "Creates a new project in the database to track tasks and sprints."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The name of the project.")
        var name: String
        @Guide(description: "A short summary of the project.")
        var summary: String
        @Guide(description: "The primary programming language of the project.")
        var language: String
        @Guide(description: "Optional URL of the repository.")
        var repoURL: String?
        @Guide(description: "Optional local file path of the project.")
        var localPath: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            try await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                let project = ProjectModel(
                    name: arguments.name,
                    summary: arguments.summary,
                    language: arguments.language,
                    repoURL: arguments.repoURL,
                    localPath: arguments.localPath
                )
                
                context.insert(project)
                try context.save()
                return "SUCCESS: Project '\(project.name)' created with ID \(project.id)."
            }
        }
    }
}

// MARK: - Create Sprint Tool
struct CreateSprintTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "create_sprint"
    let description = "Creates a new sprint for a project to organize tasks."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The UUID of the project.")
        var projectID: String
        @Guide(description: "The name of the sprint.")
        var name: String
        @Guide(description: "The goal of the sprint.")
        var goal: String
        @Guide(description: "Start date of the sprint (ISO8601 or YYYY-MM-DD).")
        var startDateString: String
        @Guide(description: "End date of the sprint (ISO8601 or YYYY-MM-DD).")
        var endDateString: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            try await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                guard let projUUID = UUID(uuidString: arguments.projectID) else {
                    return "ERROR: Invalid project ID format."
                }
                
                let descriptor = FetchDescriptor<ProjectModel>()
                guard let projects = try? context.fetch(descriptor),
                      let project = projects.first(where: { $0.id == projUUID }) else {
                    return "ERROR: Project not found."
                }
                
                let formatter = ISO8601DateFormatter()
                let simpleFormatter = DateFormatter()
                simpleFormatter.dateFormat = "yyyy-MM-dd"
                
                let startDate = formatter.date(from: arguments.startDateString) 
                    ?? simpleFormatter.date(from: arguments.startDateString) 
                    ?? Date()
                
                let endDate = formatter.date(from: arguments.endDateString) 
                    ?? simpleFormatter.date(from: arguments.endDateString) 
                    ?? Date().addingTimeInterval(86400 * 14) // 2 weeks default
                
                let sprint = SprintModel(
                    name: arguments.name,
                    goal: arguments.goal,
                    startDate: startDate,
                    endDate: endDate
                )
                sprint.project = project
                project.sprints.append(sprint)
                
                context.insert(sprint)
                try context.save()
                return "SUCCESS: Sprint '\(sprint.name)' created for project '\(project.name)'."
            }
        }
    }
}

// MARK: - Create Task Tool
struct CreateTaskTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "create_task"
    let description = "Creates a new task associated with a project and optionally a sprint."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The UUID of the project.")
        var projectID: String
        @Guide(description: "Optional UUID of the sprint.")
        var sprintID: String?
        @Guide(description: "The title of the task.")
        var title: String
        @Guide(description: "The description or details of the task.")
        var detail: String?
        @Guide(description: "The priority: low, medium, high.")
        var priority: String
        @Guide(description: "Estimated hours to complete.")
        var estimatedHours: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            try await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                guard let projUUID = UUID(uuidString: arguments.projectID) else {
                    return "ERROR: Invalid project ID format."
                }
                
                let projDesc = FetchDescriptor<ProjectModel>()
                guard let projects = try? context.fetch(projDesc),
                      let project = projects.first(where: { $0.id == projUUID }) else {
                    return "ERROR: Project not found."
                }
                
                let taskPriority: TaskPriority
                switch arguments.priority.lowercased() {
                case "low": taskPriority = .low
                case "high": taskPriority = .high
                default: taskPriority = .medium
                }
                
                let task = TaskModel(
                    title: arguments.title,
                    detail: arguments.detail ?? "",
                    priority: taskPriority,
                    estimatedHours: arguments.estimatedHours
                )
                task.project = project
                project.tasks.append(task)
                
                if let sprintIDStr = arguments.sprintID, let sprintUUID = UUID(uuidString: sprintIDStr) {
                    let sprintDesc = FetchDescriptor<SprintModel>()
                    if let sprints = try? context.fetch(sprintDesc),
                       let sprint = sprints.first(where: { $0.id == sprintUUID }) {
                        task.sprint = sprint
                        sprint.tasks.append(task)
                    }
                }
                
                context.insert(task)
                try context.save()
                return "SUCCESS: Task '\(task.title)' created under project '\(project.name)' with ID \(task.id)."
            }
        }
    }
}

// MARK: - Update Task Status Tool
struct UpdateTaskStatusTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "update_task_status"
    let description = "Updates the status of a task and records actual hours spent."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The UUID of the task.")
        var taskID: String
        @Guide(description: "The new status: backlog, todo, in_progress, review, completed.")
        var status: String
        @Guide(description: "Actual hours spent so far or for completion.")
        var actualHours: Double?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            try await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                guard let taskUUID = UUID(uuidString: arguments.taskID) else {
                    return "ERROR: Invalid task ID format."
                }
                
                let desc = FetchDescriptor<TaskModel>()
                guard let tasks = try? context.fetch(desc),
                      let task = tasks.first(where: { $0.id == taskUUID }) else {
                    return "ERROR: Task not found."
                }
                
                let taskStatus: TaskStatus
                switch arguments.status.lowercased().replacingOccurrences(of: "_", with: "") {
                case "backlog": taskStatus = .backlog
                case "todo": taskStatus = .todo
                case "inprogress": taskStatus = .inProgress
                case "review": taskStatus = .review
                case "completed", "done": taskStatus = .done
                default: taskStatus = .backlog
                }
                
                task.status = taskStatus
                if let hours = arguments.actualHours {
                    task.actualHours = hours
                }
                
                if taskStatus == .done {
                    task.completedAt = Date()
                }
                
                try context.save()
                return "SUCCESS: Task '\(task.title)' status updated to \(taskStatus.rawValue)."
            }
        }
    }
}

// MARK: - List Projects Tool
struct ListProjectsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "list_projects"
    let description = "Lists all active projects tracked in the database."

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                let descriptor = FetchDescriptor<ProjectModel>()
                guard let projects = try? context.fetch(descriptor) else {
                    return "ERROR: Failed to fetch projects."
                }
                
                if projects.isEmpty {
                    return "No projects found."
                }
                
                var result = "## Registered Projects:\n\n"
                for project in projects {
                    result += "• **\(project.name)** (ID: \(project.id))\n"
                    result += "  - Summary: \(project.summary)\n"
                    result += "  - Language: \(project.language)\n"
                    if let path = project.localPath {
                        result += "  - Path: \(path)\n"
                    }
                    result += "  - Tasks count: \(project.tasks.count)\n"
                    result += "  - Sprints count: \(project.sprints.count)\n\n"
                }
                return result
            }
        }
    }
}

// MARK: - List Tasks Tool
struct ListTasksTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "list_tasks"
    let description = "Lists tasks for a specific project or sprint."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Optional project UUID to filter by.")
        var projectID: String?
        @Guide(description: "Optional sprint UUID to filter by.")
        var sprintID: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                let descriptor = FetchDescriptor<TaskModel>()
                guard var tasks = try? context.fetch(descriptor) else {
                    return "ERROR: Failed to fetch tasks."
                }
                
                if let projIDStr = arguments.projectID, let projUUID = UUID(uuidString: projIDStr) {
                    tasks = tasks.filter { $0.project?.id == projUUID }
                }
                
                if let sprintIDStr = arguments.sprintID, let sprintUUID = UUID(uuidString: sprintIDStr) {
                    tasks = tasks.filter { $0.sprint?.id == sprintUUID }
                }
                
                if tasks.isEmpty {
                    return "No tasks found matching criteria."
                }
                
                var result = "## Tasks (\(tasks.count)):\n\n"
                for task in tasks {
                    result += "• **[\(task.status.rawValue)] \(task.title)** (ID: \(task.id))\n"
                    result += "  - Detail: \(task.detail)\n"
                    result += "  - Priority: \(task.priority.rawValue)\n"
                    if let est = task.estimatedHours {
                        result += "  - Est: \(est) hours\n"
                    }
                    if let act = task.actualHours {
                        result += "  - Actual: \(act) hours\n"
                    }
                    result += "\n"
                }
                return result
            }
        }
    }
}

// MARK: - List Sprints Tool
struct ListSprintsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "list_sprints"
    let description = "Lists sprints for a specific project."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The project UUID.")
        var projectID: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            await MainActor.run {
                let orch = orchestrator.orchestrator
                guard let context = orch.modelContext else {
                    return "ERROR: Database context not available."
                }
                
                guard let projUUID = UUID(uuidString: arguments.projectID) else {
                    return "ERROR: Invalid project ID format."
                }
                
                let descriptor = FetchDescriptor<SprintModel>()
                guard let allSprints = try? context.fetch(descriptor) else {
                    return "ERROR: Failed to fetch sprints."
                }
                
                let sprints = allSprints.filter { $0.project?.id == projUUID }
                if sprints.isEmpty {
                    return "No sprints found for project."
                }
                
                var result = "## Project Sprints:\n\n"
                for sprint in sprints {
                    result += "• **\(sprint.name)** (ID: \(sprint.id))\n"
                    result += "  - Goal: \(sprint.goal)\n"
                    result += "  - Dates: \(sprint.startDate) to \(sprint.endDate)\n"
                    result += "  - Status: \(sprint.status.rawValue)\n"
                    result += "  - Tasks count: \(sprint.tasks.count)\n\n"
                }
                return result
            }
        }
    }
}
