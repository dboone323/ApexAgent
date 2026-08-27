import Testing
import Foundation
import SwiftData
import SharedModels
import SharedKit
@testable import ApexAgentCore

@MainActor
@Suite("SwiftDataPersistenceTests")
struct SwiftDataPersistenceTests {

    private func makeTestContainer() throws -> ModelContainer {
        let schema = Schema([
            Conversation.self,
            Message.self,
            AgentMemory.self,
            AppPermissions.self,
            ProjectModel.self,
            TaskModel.self,
            SprintModel.self,
            CodeIssueModel.self,
            ReviewSession.self,
            Skill.self,
            Routine.self,
            BotProfile.self,
            BotMemoryEntry.self,
            DailyBriefing.self,
            WeeklyReflection.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }

    @Test func testFullModelSchemaPersistenceAndQuery() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)

        // 1. Conversation and Message
        let conversation = Conversation(title: "Architecture Discussion")
        let message1 = Message(role: .user, content: "What is the concurrency model?")
        let message2 = Message(role: .assistant, content: "Swift 6.4 strict concurrency with actors.")
        message1.conversation = conversation
        message2.conversation = conversation
        conversation.messages = [message1, message2]
        context.insert(conversation)

        // 2. Project, Sprint, Task, ReviewSession, CodeIssue
        let project = ProjectModel(name: "ApexAgent v2", summary: "Autonomous Agent Runtime", language: "Swift", repoURL: "https://github.com/dboone323/ApexAgent", localPath: "/tmp/apex")
        let sprint = SprintModel(name: "Sprint 1", goal: "Complete M1 Evaluation", startDate: Date(), endDate: Date().addingTimeInterval(86400 * 7))
        sprint.project = project
        let task = TaskModel(title: "Verify SwiftData Cascades", detail: "Real SwiftData test suite", status: .inProgress, priority: .high)
        task.project = project
        task.sprint = sprint
        let reviewSession = ReviewSession(fileName: "Models.swift", summary: "Cascade rules audit", suggestions: ["Ensure deleteRule is cascade"])
        reviewSession.project = project
        let codeIssue = CodeIssueModel(line: 42, message: "Cascade relationship validated", severity: .info)
        codeIssue.session = reviewSession
        
        project.tasks = [task]
        project.sprints = [sprint]
        project.reviewSessions = [reviewSession]
        reviewSession.issues = [codeIssue]
        
        context.insert(project)

        // 3. BotProfile and BotMemoryEntry
        let bot = BotProfile(name: "Architect", title: "Lead Systems Architect", descriptionText: "Specialized in actor isolation and data safety")
        let memoryEntry = BotMemoryEntry(key: "preferred_concurrency", value: "strict_complete", botProfileId: bot.id)
        context.insert(bot)
        context.insert(memoryEntry)

        // 4. DailyBriefing and WeeklyReflection
        let briefing = DailyBriefing(source: "apex_agent", mood: "productive", budgetAlertStatus: "nominal", habitCompletionCount: 3, activePowerUp: true)
        let reflection = WeeklyReflection(text: "M1 strict concurrency and test matrix verified with zero regressions.")
        context.insert(briefing)
        context.insert(reflection)

        // 5. Skill and Routine
        let skill = Skill(name: "Code Audit", descriptionText: "Audits source for strict concurrency compliance", scriptPath: "/scripts/audit.sh", parameterSchemaJSON: "{}", category: "Quality")
        let routine = Routine(name: "Morning Triage", descriptionText: "Run automated test matrix", trigger: .manual)
        context.insert(skill)
        context.insert(routine)

        // 6. AppPermissions and AgentMemory
        let permissions = AppPermissions()
        permissions.desktopFolderAllowed = true
        permissions.documentsFolderAllowed = true
        let agentMemory = AgentMemory(key: "last_run", val: "m1_complete")
        context.insert(permissions)
        context.insert(agentMemory)

        try context.save()

        // Fetch and verify all records exist
        let fetchedConversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(fetchedConversations.count == 1)
        #expect(fetchedConversations.first?.title == "Architecture Discussion")
        #expect(fetchedConversations.first?.messages.count == 2)

        let fetchedProjects = try context.fetch(FetchDescriptor<ProjectModel>())
        #expect(fetchedProjects.count == 1)
        #expect(fetchedProjects.first?.name == "ApexAgent v2")
        #expect(fetchedProjects.first?.tasks.count == 1)
        #expect(fetchedProjects.first?.sprints.count == 1)
        #expect(fetchedProjects.first?.reviewSessions.count == 1)

        let fetchedBots = try context.fetch(FetchDescriptor<BotProfile>())
        #expect(fetchedBots.count == 1)
        #expect(fetchedBots.first?.name == "Architect")

        let fetchedBriefings = try context.fetch(FetchDescriptor<DailyBriefing>())
        #expect(fetchedBriefings.count == 1)
        #expect(fetchedBriefings.first?.mood == "productive")

        let fetchedReflections = try context.fetch(FetchDescriptor<WeeklyReflection>())
        #expect(fetchedReflections.count == 1)
        #expect(fetchedReflections.first?.text.contains("strict concurrency") == true)
    }

    @Test func testConversationCascadeDeletion() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)

        let conversation = Conversation(title: "Ephemeral Chat")
        let msg1 = Message(role: .user, content: "Temp 1")
        let msg2 = Message(role: .assistant, content: "Temp 2")
        msg1.conversation = conversation
        msg2.conversation = conversation
        conversation.messages = [msg1, msg2]
        context.insert(conversation)
        try context.save()

        let initialMessages = try context.fetch(FetchDescriptor<Message>())
        #expect(initialMessages.count == 2)

        // Delete conversation
        context.delete(conversation)
        try context.save()

        let remainingConversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(remainingConversations.isEmpty)

        let remainingMessages = try context.fetch(FetchDescriptor<Message>())
        #expect(remainingMessages.isEmpty, "Messages must be deleted via cascade rule when parent conversation is deleted")
    }

    @Test func testProjectCascadeDeletion() throws {
        let container = try makeTestContainer()
        let context = ModelContext(container)

        let project = ProjectModel(name: "Temporary Project", summary: "Testing cascading delete", language: "Swift", localPath: "/tmp/proj")
        let sprint = SprintModel(name: "Temp Sprint", goal: "Test goal", startDate: Date(), endDate: Date().addingTimeInterval(3600))
        sprint.project = project
        let task = TaskModel(title: "Temp Task", detail: "Detail", status: .backlog, priority: .medium)
        task.project = project
        task.sprint = sprint
        let session = ReviewSession(fileName: "Temp.swift", summary: "Summary", suggestions: ["None"])
        session.project = project
        let issue = CodeIssueModel(line: 1, message: "Issue", severity: .warning)
        issue.session = session
        
        project.sprints = [sprint]
        project.tasks = [task]
        project.reviewSessions = [session]
        session.issues = [issue]

        context.insert(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).count == 1)

        // Delete project
        context.delete(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).isEmpty, "Tasks must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).isEmpty, "Sprints must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).isEmpty, "ReviewSessions must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).isEmpty, "CodeIssues must cascade delete with review session")
    }

    @Test func testTraceBusFilteredStreamLifecycle() async {
        let bus = TraceBus.shared
        let category = "concurrency_test_\(UUID().uuidString)"
        let stream = bus.stream(forCategory: category)

        let testTask = Task {
            var received: [TraceEvent] = []
            for await event in stream {
                received.append(event)
                if received.count >= 2 {
                    break
                }
            }
            return received
        }

        // Allow stream to set up
        try? await Task.sleep(nanoseconds: 30_000_000)

        bus.append(TraceEvent(source: category, operation: "op1", detail: "d1"))
        bus.append(TraceEvent(source: "other_cat", operation: "op_other", detail: "ignored"))
        bus.append(TraceEvent(source: category, operation: "op2", detail: "d2"))

        let results = await testTask.value
        #expect(results.count == 2)
        #expect(results[0].operation == "op1")
        #expect(results[1].operation == "op2")
    }
}
