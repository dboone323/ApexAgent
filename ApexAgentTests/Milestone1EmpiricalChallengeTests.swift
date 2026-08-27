import Testing
import Foundation
import SwiftData
import SharedModels
import SharedKit
@testable import ApexAgentCore

// MARK: - Milestone 1 Empirical Challenge Tests (Challenger 2)

@Suite("Milestone1EmpiricalChallengeTests")
struct Milestone1EmpiricalChallengeTests {

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

    // MARK: - 1. SwiftData Persistence, Migration Consistency & Transaction Rollback

    @Test func testModelContextRollbackAndDiscardUncommittedChanges() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        // Step 1: Insert uncommitted objects and verify rollback discards them
        let conv1 = Conversation(title: "Uncommitted Chat")
        let msg1 = Message(role: .user, content: "Uncommitted user message")
        msg1.conversation = conv1
        conv1.messages = [msg1]
        context.insert(conv1)

        let project1 = ProjectModel(name: "Uncommitted Project", summary: "Testing rollback", language: "Swift")
        context.insert(project1)

        let bot1 = BotProfile(name: "Uncommitted Bot", title: "Tester", descriptionText: "Ephemeral")
        context.insert(bot1)

        // Perform ModelContext rollback
        context.rollback()

        // Fetch and assert nothing was persisted
        let fetchedConvs = try context.fetch(FetchDescriptor<Conversation>())
        #expect(fetchedConvs.isEmpty, "Uncommitted conversations must be discarded on rollback")

        let fetchedProjects = try context.fetch(FetchDescriptor<ProjectModel>())
        #expect(fetchedProjects.isEmpty, "Uncommitted projects must be discarded on rollback")

        let fetchedBots = try context.fetch(FetchDescriptor<BotProfile>())
        #expect(fetchedBots.isEmpty, "Uncommitted bots must be discarded on rollback")

        // Step 2: Commit baseline data, mutate without saving, and rollback
        let committedProject = ProjectModel(name: "Committed Project", summary: "Baseline summary", language: "Swift")
        let committedTask = TaskModel(title: "Committed Task", detail: "Original detail", status: .backlog, priority: .low)
        committedTask.project = committedProject
        committedProject.tasks = [committedTask]
        context.insert(committedProject)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).count == 1)

        // Mutate committed project in memory
        committedProject.name = "Mutated Project Name"
        committedProject.summary = "Mutated summary"
        let uncommittedTask = TaskModel(title: "Uncommitted Task 2", detail: "Should be dropped", status: .inProgress, priority: .high)
        uncommittedTask.project = committedProject
        context.insert(uncommittedTask)

        // Rollback uncommitted mutations
        context.rollback()

        let refreshedProjects = try context.fetch(FetchDescriptor<ProjectModel>())
        #expect(refreshedProjects.count == 1)
        guard let p = refreshedProjects.first else {
            Issue.record("Committed project missing after rollback")
            return
        }
        #expect(p.name == "Committed Project", "Committed project name should revert to persisted snapshot")
        #expect(p.summary == "Baseline summary", "Committed project summary should revert to persisted snapshot")

        let allTasks = try context.fetch(FetchDescriptor<TaskModel>())
        #expect(allTasks.count == 1, "Uncommitted task inserted after commit must be rolled back")
        #expect(allTasks.first?.title == "Committed Task")

        // Step 3: Delete committed object in context without saving, then rollback
        context.delete(committedProject)
        context.rollback()

        let projectsAfterDeleteRollback = try context.fetch(FetchDescriptor<ProjectModel>())
        #expect(projectsAfterDeleteRollback.count == 1, "Deleted entity must be restored if transaction is rolled back")
    }

    @Test func testMultiLevelRelationalIntegrityAndCascadeRollback() throws {
        let container = try makeInMemoryContainer()
        let context = ModelContext(container)

        let project = ProjectModel(name: "Graph Project", summary: "Graph integrity test", language: "Swift")
        context.insert(project)

        let sprint = SprintModel(name: "Sprint 1", startDate: Date(), endDate: Date().addingTimeInterval(86400 * 7))
        sprint.project = project
        project.sprints.append(sprint)
        context.insert(sprint)

        let reviewSession = ReviewSession(fileName: "TestEngine.swift", summary: "Engine Code Review")
        reviewSession.project = project
        project.reviewSessions.append(reviewSession)
        context.insert(reviewSession)

        for i in 1...5 {
            let task = TaskModel(title: "Task \(i)", detail: "Detail \(i)", status: .inProgress, priority: .medium)
            task.project = project
            task.sprint = sprint
            sprint.tasks.append(task)
            project.tasks.append(task)
            context.insert(task)

            let issue = CodeIssueModel(line: i * 10, message: "Issue \(i)", severity: .warning)
            issue.session = reviewSession
            reviewSession.issues.append(issue)
            context.insert(issue)
        }

        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).count == 5)
        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).count == 5)

        // Intermediate delete of reviewSession -> cascades to 5 CodeIssues
        context.delete(reviewSession)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ReviewSession>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<CodeIssueModel>()).isEmpty, "CodeIssueModels must cascade delete with ReviewSession")
        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).count == 1, "Project must remain intact")
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).count == 1, "Sprint must remain intact")
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).count == 5, "Tasks must remain intact")

        // Root delete of project -> cascades to Sprint and Tasks
        context.delete(project)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<ProjectModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SprintModel>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<TaskModel>()).isEmpty)
    }

    @Test func testApexSuiteSchemaV1AndMigrationPlanConsistency() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ApexSuiteMigration_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        let storeURL = tempDir.appendingPathComponent("versioned_suite.store")
        let config = ModelConfiguration(url: storeURL)

        let convID = UUID()
        let memoryID = UUID()

        // Phase 1: Initialize container with ApexSuiteSchemaV1 & MigrationPlan, populate records
        do {
            let container1 = try ModelContainer(
                for: Schema(versionedSchema: ApexSuiteSchemaV1.self),
                migrationPlan: ApexSuiteMigrationPlan.self,
                configurations: [config]
            )
            let context1 = ModelContext(container1)

            let conv = AgentConversation(id: convID, title: "Schema V1 Conversation")
            let msg = AgentMessage(role: SharedModels.MessageRole.user, userText: "Prompt payload", responseText: "Response payload")
            msg.conversation = conv
            conv.messages = [msg]
            context1.insert(conv)

            let embedding = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
            let mem = AgentMemoryEntry(id: memoryID, content: "Vector memory content", embedding: embedding, source: .userChat)
            context1.insert(mem)

            try context1.save()
        }

        // Phase 2: Reopen container from disk and verify schema fidelity and binary data integrity
        do {
            let container2 = try ModelContainer(
                for: Schema(versionedSchema: ApexSuiteSchemaV1.self),
                migrationPlan: ApexSuiteMigrationPlan.self,
                configurations: [config]
            )
            let context2 = ModelContext(container2)

            let convs = try context2.fetch(FetchDescriptor<AgentConversation>())
            #expect(convs.count == 1)
            #expect(convs.first?.id == convID)
            #expect(convs.first?.title == "Schema V1 Conversation")
            #expect(convs.first?.messages.count == 1)
            #expect(convs.first?.messages.first?.userText == "Prompt payload")
            #expect(convs.first?.messages.first?.responseText == "Response payload")

            let mems = try context2.fetch(FetchDescriptor<AgentMemoryEntry>())
            #expect(mems.count == 1)
            #expect(mems.first?.id == memoryID)
            #expect(mems.first?.content == "Vector memory content")
            #expect(mems.first?.embedding == Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE]))
        }
    }

    @Test func testConcurrentModelContextRollbackIsolation() async throws {
        let container = try makeInMemoryContainer()

        actor ConcurrencyTestWorker {
            let container: ModelContainer
            init(container: ModelContainer) {
                self.container = container
            }

            func runBatch(batchId: Int, shouldRollback: Bool) throws {
                let context = ModelContext(container)
                let conv = Conversation(title: "Batch \(batchId)")
                context.insert(conv)

                for i in 1...10 {
                    let msg = Message(role: .user, content: "Batch \(batchId) Message \(i)")
                    msg.conversation = conv
                    context.insert(msg)
                }

                if shouldRollback {
                    context.rollback()
                } else {
                    try context.save()
                }
            }
        }

        let worker = ConcurrencyTestWorker(container: container)

        // Launch 10 tasks: even batches commit, odd batches rollback
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 1...10 {
                let shouldRollback = (i % 2 != 0)
                group.addTask {
                    try await worker.runBatch(batchId: i, shouldRollback: shouldRollback)
                }
            }
            try await group.waitForAll()
        }

        let mainContext = ModelContext(container)
        let conversations = try mainContext.fetch(FetchDescriptor<Conversation>())
        #expect(conversations.count == 5, "Exactly 5 committed batches should exist")

        let messages = try mainContext.fetch(FetchDescriptor<Message>())
        #expect(messages.count == 50, "Exactly 50 committed messages should exist (10 per committed batch)")
    }

    // MARK: - 2. Tool Execution Permissions (ApprovalPolicy), Confirmation Gating & Sandboxing

    @Test func testAdversarialDestructiveCommandGating() {
        let adversarialDestructivePayloads: [(tool: String, cmd: String)] = [
            ("run_shell_command", "rm -rf /"),
            ("run_shell_command", "rm -fr /Users/test/workspace"),
            ("run_shell_command", "rm -r -f /var/log"),
            ("run_shell_command", "rm -f -r /tmp/test"),
            ("run_shell_command", "sudo rm -rf /etc"),
            ("run_shell_command", "chmod -R 777 /"),
            ("run_shell_command", "mkfs.ext4 /dev/sda1"),
            ("run_shell_command", "diskutil eraseDisk APFS CleanDisk /dev/disk2"),
            ("run_shell_command", "diskutil eraseVolume APFS MyVol /dev/disk2s1"),
            ("run_shell_command", "dd if=/dev/zero of=/dev/rdisk0 bs=1m"),
            ("run_shell_command", "dd of=/dev/disk1 bs=1m count=100"),
            ("run_shell_command", "git push origin main --force"),
            ("run_shell_command", "git push origin main --force-with-lease"),
            ("run_shell_command", "git reset --hard HEAD~1"),
            ("run_shell_command", "psql -d app -c 'DROP DATABASE production;'"),
            ("run_shell_command", "psql -d app -c 'DROP TABLE users;'"),
            ("run_shell_command", "psql -d app -c 'TRUNCATE TABLE sessions;'"),
            ("run_shell_command", "shutdown -h now"),
            ("run_shell_command", "reboot"),
            ("run_shell_command", "halt"),
            ("run_shell_command", ":(){ :|:& };:"),
            ("computer_exec", "rm -rf /tmp/data"),
            ("terminal", "diskutil eraseDisk APFS Wipe /dev/disk3")
        ]

        for payload in adversarialDestructivePayloads {
            let verdict = ApprovalPolicy.verdict(
                tool: payload.tool,
                summary: payload.cmd,
                alwaysAllow: ["run_shell_command:git", "run_shell_command:rm", "run_shell_command:psql", payload.tool],
                autoApprove: true,
                isContainerSandboxed: false
            )
            #expect(verdict.approve == nil, "Destructive payload '\(payload.cmd)' MUST NOT be auto-approved")
            #expect(verdict.source == .destructiveGuard, "Destructive payload '\(payload.cmd)' MUST trigger destructiveGuard")
            #expect(verdict.rule != nil, "Destructive payload '\(payload.cmd)' MUST identify triggering rule")
        }
    }

    @Test func testAdversarialSensitiveCredentialGating() {
        let adversarialSensitivePayloads: [(tool: String, cmd: String)] = [
            ("run_shell_command", "cat .env"),
            ("run_shell_command", "cat .env.production"),
            ("run_shell_command", "head -n 20 config/.env.local"),
            ("run_shell_command", "cat ~/.ssh/id_rsa"),
            ("run_shell_command", "cat ~/.ssh/id_ed25519"),
            ("run_shell_command", "cat ~/.ssh/authorized_keys"),
            ("run_shell_command", "cat ~/.aws/credentials"),
            ("run_shell_command", "cat ~/.netrc"),
            ("run_shell_command", "cat ~/.npmrc"),
            ("run_shell_command", "cat ~/.pypirc"),
            ("run_shell_command", "cat ~/.docker/config.json"),
            ("run_shell_command", "security find-generic-password -s 'OpenAI'"),
            ("run_shell_command", "security find-internet-password -s 'GitHub'"),
            ("run_shell_command", "cat serviceaccount.json"),
            ("run_shell_command", "cat credentials.json"),
            ("run_shell_command", "security dump-keychain")
        ]

        for payload in adversarialSensitivePayloads {
            let verdict = ApprovalPolicy.verdict(
                tool: payload.tool,
                summary: payload.cmd,
                alwaysAllow: ["run_shell_command:cat", "run_shell_command:head", "run_shell_command:security", payload.tool],
                autoApprove: true,
                isContainerSandboxed: false
            )
            #expect(verdict.approve == nil, "Sensitive credential payload '\(payload.cmd)' MUST NOT be auto-approved")
            #expect(verdict.source == .sensitiveGuard, "Sensitive credential payload '\(payload.cmd)' MUST trigger sensitiveGuard")
            #expect(verdict.rule != nil, "Sensitive credential payload '\(payload.cmd)' MUST identify triggering rule")
        }
    }

    @Test func testGuardsAlwaysOutrankAlwaysAllowAndAutoApprove() {
        // Even with autoApprove = true and matching alwaysAllow key, destructive commands must be blocked
        let verdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "rm -rf /Users/test/workspace",
            alwaysAllow: ["run_shell_command:rm"],
            autoApprove: true
        )
        #expect(verdict.approve == nil)
        #expect(verdict.source == .destructiveGuard)

        // Sensitive command with always-allow for tool must be blocked
        let sensitiveVerdict = ApprovalPolicy.verdict(
            tool: "read_file",
            summary: "read /Users/test/.env",
            alwaysAllow: ["read_file"],
            autoApprove: true
        )
        #expect(sensitiveVerdict.approve == nil)
        #expect(sensitiveVerdict.source == .sensitiveGuard)
    }

    @Test func testApprovalKeyParsingEdgeCases() {
        // 1. Env prefixes and sudo skipping
        #expect(ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "FOO=bar BAZ=123 sudo /usr/bin/git status") == "run_shell_command:git")
        #expect(ApprovalPolicy.approvalKey(tool: "bash", summary: "sudo /opt/homebrew/bin/npm install") == "bash:npm")
        #expect(ApprovalPolicy.approvalKey(tool: "shell", summary: "VAR=test swift test") == "shell:swift")

        // 2. Bare MCP tool prefix stripping
        #expect(ApprovalPolicy.approvalKey(tool: "mcp__filesystem__read_file", summary: "read /a/b.txt") == "mcp__filesystem__read_file")

        // 3. Non-command tool returns tool name directly
        #expect(ApprovalPolicy.approvalKey(tool: "read_file", summary: "whatever") == "read_file")
        #expect(ApprovalPolicy.approvalKey(tool: "search_files", summary: "query") == "search_files")

        // 4. Empty and whitespace summaries
        #expect(ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "") == "run_shell_command")
        #expect(ApprovalPolicy.approvalKey(tool: "run_shell_command", summary: "    ") == "run_shell_command")
    }

    @Test func testUnattendedAndLocalScopeEnforcement() {
        let alwaysAllowGit = ["run_shell_command:git"]

        // 1. Unattended mode blocks grants with .unattendedBlock
        let unattendedVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "git status",
            alwaysAllow: alwaysAllowGit,
            autoApprove: true,
            unattended: true
        )
        #expect(unattendedVerdict.approve == nil)
        #expect(unattendedVerdict.source == .unattendedBlock)

        // 2. Unattended mode with no grant returns .noGrant
        let unattendedNoGrant = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "git status",
            alwaysAllow: [],
            autoApprove: false,
            unattended: true
        )
        #expect(unattendedNoGrant.approve == nil)
        #expect(unattendedNoGrant.source == .noGrant)

        // 3. Local scope without autoApprove blocks with .localComputerBlock
        let localScopeVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "git status",
            alwaysAllow: alwaysAllowGit,
            autoApprove: false,
            localScope: true
        )
        #expect(localScopeVerdict.approve == nil)
        #expect(localScopeVerdict.source == .localComputerBlock)

        // 4. Local scope WITH autoApprove permits execution
        let localScopeAutoVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "git status",
            alwaysAllow: alwaysAllowGit,
            autoApprove: true,
            localScope: true
        )
        #expect(localScopeAutoVerdict.approve != nil)
    }

    @Test func testAppleContainerSandboxBoundaries() {
        // Inside isolated container micro-VM:
        // 1. Safe package manager operations and ephemeral builds auto-approve
        let containerSafeVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "sudo apt-get update && sudo apt-get install -y clang && rm -rf /tmp/build",
            isContainerSandboxed: true
        )
        #expect(containerSafeVerdict.approve != nil)
        #expect(containerSafeVerdict.source == .containerSandbox)

        // 2. Catastrophic host disk destruction is still blocked
        let containerDiskEraseVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "diskutil eraseDisk APFS Clean /dev/disk1",
            isContainerSandboxed: true
        )
        #expect(containerDiskEraseVerdict.approve == nil)
        #expect(containerDiskEraseVerdict.source == .destructiveGuard)

        let containerDDVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "dd if=/dev/zero of=/dev/rdisk0 bs=1m",
            isContainerSandboxed: true
        )
        #expect(containerDDVerdict.approve == nil)
        #expect(containerDDVerdict.source == .destructiveGuard)

        let containerMkfsVerdict = ApprovalPolicy.verdict(
            tool: "run_shell_command",
            summary: "mkfs.vfat /dev/sdb",
            isContainerSandboxed: true
        )
        #expect(containerMkfsVerdict.approve == nil)
        #expect(containerMkfsVerdict.source == .destructiveGuard)
    }

    @Test @MainActor func testSecuritySandboxErrorAndPathValidation() throws {
        let orchestrator = AgentOrchestrator()
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.standardized.path
        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        // 1. Denied permissions produce exact SecuritySandboxError enum cases
        orchestrator.permissions = AppPermissions(
            musicFolderAllowed: false,
            desktopFolderAllowed: false,
            documentsFolderAllowed: false,
            downloadsFolderAllowed: false
        )

        do {
            try orchestrator.verifyPathAllowed(desktopPath)
            Issue.record("Expected desktopFolderRestricted")
        } catch let error {
            if case .desktopFolderRestricted = error {} else {
                Issue.record("Expected desktopFolderRestricted but got \(error)")
            }
        }

        do {
            try orchestrator.verifyPathAllowed(documentsPath)
            Issue.record("Expected documentsFolderRestricted")
        } catch let error {
            if case .documentsFolderRestricted = error {} else {
                Issue.record("Expected documentsFolderRestricted but got \(error)")
            }
        }

        do {
            try orchestrator.verifyPathAllowed(downloadsPath)
            Issue.record("Expected downloadsFolderRestricted")
        } catch let error {
            if case .downloadsFolderRestricted = error {} else {
                Issue.record("Expected downloadsFolderRestricted but got \(error)")
            }
        }

        do {
            try orchestrator.verifyPathAllowed(musicPath)
            Issue.record("Expected musicFolderRestricted")
        } catch let error {
            if case .musicFolderRestricted = error {} else {
                Issue.record("Expected musicFolderRestricted but got \(error)")
            }
        }

        // 2. Arbitrary path outside workspace throws .pathViolation
        #expect(throws: SecuritySandboxError.self) {
            try orchestrator.verifyPathAllowed("/etc/passwd")
        }
        #expect(throws: SecuritySandboxError.self) {
            try orchestrator.verifyPathAllowed("/usr/local/bin/secret")
        }

        // 3. Verify error description formatting
        let pathErr = SecuritySandboxError.pathViolation("/etc/shadow")
        #expect(pathErr.description.contains("Security sandbox violation: path '/etc/shadow' is outside the allowed workspace"))

        let symErr = SecuritySandboxError.symlinkTraversal("/tmp/evil_symlink")
        #expect(symErr.description.contains("contains symlinks resolving outside"))
    }

    // MARK: - 3. Token Window Estimators & Context Overflow Guards

    @Test func testMessageCompressionHelperBoundaries() {
        // 1. Empty message array
        let emptyResult = MessageCompressionHelper.compressMessages([])
        #expect(emptyResult.isEmpty)

        // 2. Small arrays (<= keepRecent + 1) remain untouched
        let msg1 = ChatMessage(role: .user, content: "Hello 1")
        let msg2 = ChatMessage(role: .assistant, content: "Hello 2")
        let msg3 = ChatMessage(role: .user, content: "Hello 3")
        let smallArray = [msg1, msg2, msg3]
        let smallResult = MessageCompressionHelper.compressMessages(smallArray, keepRecent: 4)
        #expect(smallResult.count == 3)
        #expect(smallResult[0].content == "Hello 1")

        // 3. Historical assistant messages > 240 chars get truncated to 140 chars + "..."
        let hugeAssistantText = String(repeating: "A", count: 500)
        let recentMsg = ChatMessage(role: .user, content: "Recent turn")

        var messagesToCompress: [ChatMessage] = []
        // Add 5 historical assistant messages
        for _ in 1...5 {
            messagesToCompress.append(ChatMessage(role: .assistant, content: hugeAssistantText))
        }
        // Add 4 recent messages
        for _ in 1...4 {
            messagesToCompress.append(recentMsg)
        }

        let compressed = MessageCompressionHelper.compressMessages(messagesToCompress, keepRecent: 4)
        #expect(compressed.count == 9)

        // Check historical messages are compressed
        for i in 0..<5 {
            #expect(compressed[i].content.count == 143, "Historical assistant message must be truncated to 140 prefix + '...' (143 chars)")
            #expect(compressed[i].content.hasSuffix("..."))
        }

        // Check recent messages are preserved untouched
        for i in 5..<9 {
            #expect(compressed[i].content == "Recent turn")
        }

        // 4. Large user and system messages are preserved in full
        let hugeUserMsg = ChatMessage(role: .user, content: String(repeating: "U", count: 500))
        let hugeSystemMsg = ChatMessage(role: .system, content: String(repeating: "S", count: 500))
        let mixedArray = [hugeUserMsg, hugeSystemMsg, recentMsg, recentMsg, recentMsg, recentMsg]
        let compressedMixed = MessageCompressionHelper.compressMessages(mixedArray, keepRecent: 4)
        #expect(compressedMixed[0].content.count == 500, "User messages must not be truncated by compression helper")
        #expect(compressedMixed[1].content.count == 500, "System messages must not be truncated by compression helper")
    }

    @Test func testTokenCountEstimationStress() {
        // 1. Zero messages -> returns 1 (lower bound clamp)
        #expect(MessageCompressionHelper.estimateTokenCount(messages: []) == 1)

        // 2. Messages with 0 characters -> returns 1
        let emptyMsg = ChatMessage(role: .user, content: "")
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [emptyMsg]) == 1)

        // 3. Short strings (1-3 chars) -> returns 1 (max(1, total/4))
        let shortMsg1 = ChatMessage(role: .user, content: "a")
        let shortMsg2 = ChatMessage(role: .user, content: "ab")
        let shortMsg3 = ChatMessage(role: .user, content: "abc")
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [shortMsg1]) == 1)
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [shortMsg2]) == 1)
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [shortMsg3]) == 1)

        // 4. Exactly 4 chars -> returns 1; 8 chars -> returns 2; 100,000 chars -> returns 25,000
        let fourCharMsg = ChatMessage(role: .user, content: "1234")
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [fourCharMsg]) == 1)

        let eightCharMsg = ChatMessage(role: .user, content: "12345678")
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [eightCharMsg]) == 2)

        let hugeMsg = ChatMessage(role: .user, content: String(repeating: "x", count: 100_000))
        #expect(MessageCompressionHelper.estimateTokenCount(messages: [hugeMsg]) == 25_000)

        // 5. Multi-byte Unicode, Emojis, and CJK text
        let unicodeMsg = ChatMessage(role: .user, content: "🚀 Swift 6.4 严格并发验证 🧠 ModelContainer 深度压力测试 🛡️")
        let tokenEstimate = MessageCompressionHelper.estimateTokenCount(messages: [unicodeMsg])
        #expect(tokenEstimate > 0)
    }
}
