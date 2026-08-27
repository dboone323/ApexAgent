import Testing
import Foundation
import SwiftData
import AppKit
import SharedModels
import SharedKit
@testable import ApexAgentCore

@Suite("SwiftDataStressVerificationTests")
struct SwiftDataStressVerificationTests {

    private func makeInMemoryContainer() throws -> ModelContainer {
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

    private func makeDiskBackedContainer(at tempURL: URL) throws -> ModelContainer {
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
        let config = ModelConfiguration(url: tempURL)
        return try ModelContainer(for: schema, configurations: config)
    }

    // MARK: - Test 1: Deep Multi-Level Graph & Relational Integrity
    @Test func testDeepGraphRelationalIntegrity() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let project = ProjectModel(
            name: "Apex HyperScale",
            summary: "Multi-Agent System Architecture",
            language: "Swift",
            repoURL: "https://github.com/dboone323/ApexAgent",
            localPath: "/Users/danielstevens/Developer/ApexAgent"
        )
        context.insert(project)

        var createdSprints: [SprintModel] = []
        var allCreatedTasks: [TaskModel] = []
        var createdSessions: [ReviewSession] = []
        var allCreatedIssues: [CodeIssueModel] = []

        for sIndex in 1...5 {
            let sprint = SprintModel(
                name: "Sprint \(sIndex)",
                goal: "Goal for sprint \(sIndex)",
                startDate: Date().addingTimeInterval(Double(sIndex * 86400 * 7)),
                endDate: Date().addingTimeInterval(Double((sIndex + 1) * 86400 * 7)),
                status: sIndex == 1 ? .active : .planned
            )
            sprint.project = project
            context.insert(sprint)
            createdSprints.append(sprint)

            for tIndex in 1...10 {
                let task = TaskModel(
                    title: "Task S\(sIndex)-T\(tIndex)",
                    detail: "Detailed task description for S\(sIndex)T\(tIndex)",
                    status: (tIndex % 3 == 0) ? .done : (tIndex % 3 == 1 ? .inProgress : .backlog),
                    priority: (tIndex % 2 == 0) ? .high : .medium,
                    estimatedHours: Double(tIndex * 2),
                    actualHours: (tIndex % 3 == 0) ? Double(tIndex * 2) : nil,
                    tags: ["sprint\(sIndex)", "swift6", "concurrency"]
                )
                task.project = project
                task.sprint = sprint
                context.insert(task)
                allCreatedTasks.append(task)
                sprint.tasks.append(task)
                project.tasks.append(task)
            }
            project.sprints.append(sprint)
        }

        for rIndex in 1...4 {
            let session = ReviewSession(
                fileName: "Module\(rIndex)Engine.swift",
                summary: "Automated concurrency and actor audit for Module \(rIndex)",
                suggestions: ["Use TaskGroup for parallelism", "Ensure Sendable isolation"]
            )
            session.project = project
            context.insert(session)
            createdSessions.append(session)

            for iIndex in 1...8 {
                let issue = CodeIssueModel(
                    line: iIndex * 15,
                    message: "Diagnostic finding at line \(iIndex * 15) in Module \(rIndex)",
                    severity: (iIndex % 3 == 0) ? .error : (iIndex % 3 == 1 ? .warning : .info)
                )
                issue.session = session
                context.insert(issue)
                allCreatedIssues.append(issue)
                session.issues.append(issue)
            }
            project.reviewSessions.append(session)
        }

        try context.save()

        // Verify counts
        let fetchedProjects = try context.fetch(FetchDescriptor<ProjectModel>())
        #expect(fetchedProjects.count == 1)
        guard let p = fetchedProjects.first else {
            Issue.record("Project not found")
            return
        }

        #expect(p.sprints.count == 5)
        #expect(p.tasks.count == 50)
        #expect(p.reviewSessions.count == 4)

        let fetchedTasks = try context.fetch(FetchDescriptor<TaskModel>())
        #expect(fetchedTasks.count == 50)

        let fetchedIssues = try context.fetch(FetchDescriptor<CodeIssueModel>())
        #expect(fetchedIssues.count == 32)

        // Verify deep cross-reference integrity
        for sprint in p.sprints {
            #expect(sprint.project?.id == p.id)
            #expect(sprint.tasks.count == 10)
            for t in sprint.tasks {
                #expect(t.project?.id == p.id)
                #expect(t.sprint?.id == sprint.id)
            }
        }

        for session in p.reviewSessions {
            #expect(session.project?.id == p.id)
            #expect(session.issues.count == 8)
            for issue in session.issues {
                #expect(issue.session?.id == session.id)
            }
        }
    }

    // MARK: - Test 2: Multi-Level Cascade Deletion (Intermediate and Root)
    @Test func testIntermediateAndRootCascadeDeletions() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let project = ProjectModel(name: "Cascade Testbed", summary: "Stress test cascade rules", language: "Swift")
        context.insert(project)

        let sprint1 = SprintModel(name: "Sprint Alpha", startDate: Date(), endDate: Date().addingTimeInterval(86400))
        sprint1.project = project
        context.insert(sprint1)
        project.sprints.append(sprint1)

        let sprint2 = SprintModel(name: "Sprint Beta", startDate: Date().addingTimeInterval(86400), endDate: Date().addingTimeInterval(86400 * 2))
        sprint2.project = project
        context.insert(sprint2)
        project.sprints.append(sprint2)

        for i in 1...5 {
            let t1 = TaskModel(title: "Task Alpha \(i)")
            t1.project = project
            t1.sprint = sprint1
            context.insert(t1)
            sprint1.tasks.append(t1)
            project.tasks.append(t1)

            let t2 = TaskModel(title: "Task Beta \(i)")
            t2.project = project
            t2.sprint = sprint2
            context.insert(t2)
            sprint2.tasks.append(t2)
            project.tasks.append(t2)
        }

        let session1 = ReviewSession(fileName: "FileAlpha.swift", summary: "Alpha Review")
        session1.project = project
        context.insert(session1)
        project.reviewSessions.append(session1)

        let session2 = ReviewSession(fileName: "FileBeta.swift", summary: "Beta Review")
        session2.project = project
        context.insert(session2)
        project.reviewSessions.append(session2)

        for i in 1...4 {
            let issue1 = CodeIssueModel(line: i * 10, message: "Alpha issue \(i)", severity: .warning)
            issue1.session = session1
            context.insert(issue1)
            session1.issues.append(issue1)

            let issue2 = CodeIssueModel(line: i * 10, message: "Beta issue \(i)", severity: .error)
            issue2.session = session2
            context.insert(issue2)
            session2.issues.append(issue2)
        }

        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).count == 10)
        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).count == 2)
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).count == 8)

        // Sub-test A: Intermediate deletion of ReviewSession1
        // Deleting session1 should delete its 4 CodeIssues, but leave session2, its 4 CodeIssues, and Project intact
        context.delete(session1)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).count == 1)
        let remainingIssues = try context.fetch(FetchDescriptor<CodeIssueModel>())
        #expect(remainingIssues.count == 4)
        for issue in remainingIssues {
            #expect(issue.session?.id == session2.id)
        }

        // Sub-test B: Root Project deletion
        // Deleting project should cascade delete everything remaining (sprint1, sprint2, 10 tasks, session2, 4 issues)
        context.delete(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).isEmpty, "Sprints must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).isEmpty, "Tasks must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).isEmpty, "ReviewSessions must cascade delete with project")
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).isEmpty, "CodeIssues must cascade delete completely")
    }

    // MARK: - Test 3: Large Conversation Scale & External Storage Cascade
    @Test func testLargeConversationScaleAndCascade() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let conversation = Conversation(title: "Massive Session Discussion")
        context.insert(conversation)

        // Generate synthetic image data for external storage
        let imageSize = NSSize(width: 64, height: 64)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        image.unlockFocus()
        let samplePNG = image.pngData ?? Data([0x89, 0x50, 0x4E, 0x47])

        let messageCount = 200
        for i in 1...messageCount {
            let role: ApexAgentCore.MessageRole = (i % 2 == 1) ? .user : .assistant
            let hasAttachment = (i % 20 == 0)
            let msg = Message(
                role: role,
                content: "Message payload #\(i): Concurrency verification step \(i) details and log outputs.",
                attachmentsData: hasAttachment ? [samplePNG] : nil
            )
            msg.conversation = conversation
            context.insert(msg)
            conversation.messages.append(msg)
        }

        try context.save()

        let fetchedConversations = try context.fetch(FetchDescriptor<Conversation>())
        #expect(fetchedConversations.count == 1)
        #expect(fetchedConversations.first?.messages.count == messageCount)

        let fetchedMessages = try context.fetch(FetchDescriptor<Message>())
        #expect(fetchedMessages.count == messageCount)

        let messagesWithAttachments = fetchedMessages.filter { ($0.attachmentsData?.count ?? 0) > 0 }
        #expect(messagesWithAttachments.count == 10)
        #expect(messagesWithAttachments.first?.attachments.count == 1)

        // Delete conversation -> verify all 200 messages cascade delete
        context.delete(conversation)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Conversation>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Message>()).isEmpty, "All child messages must be cascade deleted")
    }

    // MARK: - Test 4: BotProfile & BotMemoryEntry Association and Query Integrity
    @Test func testBotProfileMemoryAssociationAndQuery() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let bot1 = BotProfile(
            name: "Lead Architect",
            title: "Systems Lead",
            descriptionText: "Owns core architecture and concurrency safety",
            avatarName: "cpu"
        )
        let bot2 = BotProfile(
            name: "Security Guard",
            title: "AppSec Lead",
            descriptionText: "Owns sandbox safety and approval policies",
            avatarName: "lock.shield"
        )
        context.insert(bot1)
        context.insert(bot2)

        for i in 1...15 {
            let mem1 = BotMemoryEntry(
                key: "arch_rule_\(i)",
                value: "Rule value \(i): strict actor isolation",
                source: "team_standards",
                botProfileId: bot1.id
            )
            context.insert(mem1)
        }

        for i in 1...10 {
            let mem2 = BotMemoryEntry(
                key: "sec_rule_\(i)",
                value: "Security policy \(i): no unsanitized bash commands",
                source: "security_guidelines",
                botProfileId: bot2.id
            )
            context.insert(mem2)
        }

        try context.save()

        let targetId1 = bot1.id
        let descriptor1 = FetchDescriptor<BotMemoryEntry>(predicate: #Predicate { entry in
            entry.botProfileId == targetId1
        })
        let bot1Memories = try context.fetch(descriptor1)
        #expect(bot1Memories.count == 15)

        let targetId2 = bot2.id
        let descriptor2 = FetchDescriptor<BotMemoryEntry>(predicate: #Predicate { entry in
            entry.botProfileId == targetId2
        })
        let bot2Memories = try context.fetch(descriptor2)
        #expect(bot2Memories.count == 10)

        // Verify total memory entries
        let allMemories = try context.fetch(FetchDescriptor<BotMemoryEntry>())
        #expect(allMemories.count == 25)
    }

    // MARK: - Test 5: On-Disk SQLite Persistence & Cold Relaunch Fidelity
    @Test func testOnDiskPersistenceAcrossContainerInstances() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftDataStress_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let storeURL = tempDir.appendingPathComponent("test_store.store")

        let projectID = UUID()
        let conversationID = UUID()
        let botID = UUID()

        // Phase 1: Initialize container, write rich data, and close
        do {
            let container1 = try makeDiskBackedContainer(at: storeURL)
            let context1 = ModelContext(container1)

            let project = ProjectModel(
                id: projectID,
                name: "Persistent Project",
                summary: "Cold restart validation",
                language: "Swift"
            )
            let task = TaskModel(
                title: "Persistent Task",
                detail: "Should survive container teardown",
                status: .inProgress,
                priority: .high
            )
            task.project = project
            project.tasks = [task]
            context1.insert(project)

            let conversation = Conversation(title: "Persistent Conversation")
            conversation.id = conversationID
            let msg = Message(role: ApexAgentCore.MessageRole.user, content: "Persistent message payload")
            msg.conversation = conversation
            conversation.messages = [msg]
            context1.insert(conversation)

            let bot = BotProfile(
                id: botID,
                name: "Persistent Bot",
                title: "Reliability Officer",
                descriptionText: "Validates disk flush fidelity"
            )
            let memory = BotMemoryEntry(
                key: "flush_status",
                value: "written_to_sqlite",
                botProfileId: botID
            )
            context1.insert(bot)
            context1.insert(memory)

            let skill = Skill(
                name: "Disk Audit",
                descriptionText: "Inspects SQLite file integrity",
                scriptPath: "/bin/true",
                parameterSchemaJSON: "{}",
                category: "Diagnostics"
            )
            context1.insert(skill)

            let routine = Routine(
                name: "Hourly Check",
                descriptionText: "Ensures persistence daemon is healthy",
                trigger: .timeInterval,
                scheduledMinutes: 60
            )
            context1.insert(routine)

            let briefing = DailyBriefing(source: "daily_worker", mood: "focused")
            let reflection = WeeklyReflection(text: "Database persistence across cold restart verified.")
            context1.insert(briefing)
            context1.insert(reflection)

            let perms = AppPermissions(accessibilityAllowed: true, screenRecordingAllowed: true)
            let agentMem = AgentMemory(key: "sqlite_check", val: "pass")
            context1.insert(perms)
            context1.insert(agentMem)

            try context1.save()
        }

        // Phase 2: Open a fresh container pointing to the same SQLite file on disk
        do {
            let container2 = try makeDiskBackedContainer(at: storeURL)
            let context2 = ModelContext(container2)

            let projects = try context2.fetch(FetchDescriptor<ProjectModel>())
            #expect(projects.count == 1)
            #expect(projects.first?.id == projectID)
            #expect(projects.first?.name == "Persistent Project")
            #expect(projects.first?.tasks.count == 1)
            #expect(projects.first?.tasks.first?.title == "Persistent Task")

            let conversations = try context2.fetch(FetchDescriptor<Conversation>())
            #expect(conversations.count == 1)
            #expect(conversations.first?.id == conversationID)
            #expect(conversations.first?.title == "Persistent Conversation")
            #expect(conversations.first?.messages.count == 1)
            #expect(conversations.first?.messages.first?.content == "Persistent message payload")

            let bots = try context2.fetch(FetchDescriptor<BotProfile>())
            #expect(bots.count == 1)
            #expect(bots.first?.id == botID)
            #expect(bots.first?.name == "Persistent Bot")

            let targetBotID = botID
            let memories = try context2.fetch(FetchDescriptor<BotMemoryEntry>(predicate: #Predicate { $0.botProfileId == targetBotID }))
            #expect(memories.count == 1)
            #expect(memories.first?.value == "written_to_sqlite")

            let skills = try context2.fetch(FetchDescriptor<Skill>())
            #expect(skills.count == 1)
            #expect(skills.first?.name == "Disk Audit")

            let routines = try context2.fetch(FetchDescriptor<Routine>())
            #expect(routines.count == 1)
            #expect(routines.first?.scheduledMinutes == 60)

            let briefings = try context2.fetch(FetchDescriptor<DailyBriefing>())
            #expect(briefings.count == 1)
            #expect(briefings.first?.mood == "focused")

            let reflections = try context2.fetch(FetchDescriptor<WeeklyReflection>())
            #expect(reflections.count == 1)
            #expect(reflections.first?.text.contains("Database persistence") == true)

            let permissions = try context2.fetch(FetchDescriptor<AppPermissions>())
            #expect(permissions.count == 1)
            #expect(permissions.first?.accessibilityAllowed == true)

            let agentMemories = try context2.fetch(FetchDescriptor<AgentMemory>())
            #expect(agentMemories.count == 1)
            #expect(agentMemories.first?.val == "pass")
        }
    }

    // MARK: - Test 6: Concurrent Multi-Context Background Operations
    @Test func testConcurrentModelContextOperations() async throws {
        let container = try makeInMemoryContainer()

        // Actor-isolated worker to demonstrate concurrent writes into distinct ModelContexts
        actor DatabaseWorker {
            let container: ModelContainer
            init(container: ModelContainer) {
                self.container = container
            }

            func insertConversationWithMessages(batchId: Int, messageCount: Int) throws {
                let context = ModelContext(container)
                let conv = Conversation(title: "Concurrent Conversation Batch \(batchId)")
                context.insert(conv)

                for m in 1...messageCount {
                    let msg = Message(
                        role: (m % 2 == 1) ? ApexAgentCore.MessageRole.user : ApexAgentCore.MessageRole.assistant,
                        content: "Batch \(batchId) Message \(m) concurrently processed"
                    )
                    msg.conversation = conv
                    context.insert(msg)
                    conv.messages.append(msg)
                }

                try context.save()
            }
        }

        let worker = DatabaseWorker(container: container)

        // Execute 10 concurrent worker tasks simultaneously
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                group.addTask {
                    try await worker.insertConversationWithMessages(batchId: i, messageCount: 20)
                }
            }
            try await group.waitForAll()
        }

        // Verify on MainActor context that all 10 conversations and 200 messages are persisted
        let mainContext = ModelContext(container)
        let conversations = try mainContext.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.count == 10)

        let messages = try mainContext.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 200)

        for conv in conversations {
            #expect(conv.messages.count == 20)
        }
    }

    // MARK: - Test 7: ApexSuiteSchema Container Validation
    @Test func testApexSuiteSchemaContainerLifecycle() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ApexSuiteStress_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let storeURL = tempDir.appendingPathComponent("default.store")
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: Schema(versionedSchema: ApexSuiteSchemaV1.self),
            migrationPlan: ApexSuiteMigrationPlan.self,
            configurations: [config]
        )

        let context = ModelContext(container)
        let agentConv = AgentConversation(title: "Agent Chat 1")
        let agentMsg = AgentMessage(role: SharedModels.MessageRole.user, userText: "Hello Agent", responseText: "Hello User")
        agentMsg.conversation = agentConv
        agentConv.messages = [agentMsg]
        context.insert(agentConv)

        let memEntry = AgentMemoryEntry(
            content: "Vector memory content",
            embedding: Data([0x01, 0x02, 0x03]),
            source: .userChat
        )
        context.insert(memEntry)

        try context.save()

        let fetchedConv = try context.fetch(FetchDescriptor<AgentConversation>())
        #expect(fetchedConv.count == 1)
        #expect(fetchedConv.first?.messages.count == 1)
        #expect(fetchedConv.first?.messages.first?.userText == "Hello Agent")

        let fetchedMem = try context.fetch(FetchDescriptor<AgentMemoryEntry>())
        #expect(fetchedMem.count == 1)
        #expect(fetchedMem.first?.embedding.count == 3)

        // Test cascade deletion of AgentConversation -> AgentMessage
        context.delete(agentConv)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<AgentConversation>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<AgentMessage>()).isEmpty, "AgentMessage must cascade delete with AgentConversation")
    }
}
