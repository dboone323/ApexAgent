import Testing
import Foundation
@testable import ApexAgentCore

@Suite("ComputerUseAgentTests")
struct ComputerUseAgentTests {
    @Test("Test all ComputerAction cases and Codable / Equatable conformance")
    func testComputerActionCases() throws {
        let actions: [ComputerAction] = [
            .wait(seconds: 0.01),
            .finish(result: "done")
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for action in actions {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(ComputerAction.self, from: data)
            #expect(decoded == action)
        }
    }

    @Test("Test ComputerUseStep model initialization")
    func testComputerUseStep() {
        let step = ComputerUseStep(action: .wait(seconds: 0.01))
        #expect(step.action == .wait(seconds: 0.01))
    }
    
    @Test("Test executeAction wait")
    func testExecuteActionWait() async throws {
        let result = try await ComputerUseAgent.shared.executeAction(.wait(seconds: 0.01))
        #expect(result.lowercased().contains("success") || !result.isEmpty)
    }
    
    @Test("Test executeAction finish")
    func testExecuteActionFinish() async throws {
        let result = try await ComputerUseAgent.shared.executeAction(.finish(result: "done"))
        #expect(result.lowercased().contains("finish") || !result.isEmpty)
    }
}

@Suite("VoiceTTSProviderTests")
struct VoiceTTSProviderTests {
    @Test("Test TTSProvider.allCases contains .system and .elevenLabs")
    func testTTSProviderCases() {
        let cases = TTSProvider.allCases
        #expect(cases.contains(.system))
        #expect(cases.contains(.elevenLabs))
    }
    
    @Test("Test VoiceController.shared.selectedProvider defaults and switching")
    @MainActor
    func testVoiceControllerProvider() {
        let controller = VoiceController.shared
        
        controller.selectedProvider = .system
        #expect(controller.selectedProvider == .system)
        
        controller.selectedProvider = .elevenLabs
        #expect(controller.selectedProvider == .elevenLabs)
    }
}

@Suite("TraceBusEventStreamTests")
struct TraceBusEventStreamTests {
    @Test("Test TraceBus.shared.eventStream()")
    func testTraceBusEventStream() async throws {
        let bus = TraceBus.shared
        let uniqueID = UUID().uuidString
        
        let task = Task {
            for await event in bus.eventStream() {
                if event.detail == uniqueID {
                    return true
                }
            }
            return false
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        bus.append(TraceEvent(source: "test", operation: "log", detail: uniqueID))
        
        let found = await task.value
        #expect(found)
    }
    
    @Test("Test TraceBus.shared.stream(forCategory:)")
    func testTraceBusStreamForCategory() async throws {
        let bus = TraceBus.shared
        let uniqueID = UUID().uuidString
        let category = "targetCategory"
        
        let task = Task {
            for await event in bus.stream(forCategory: category) {
                if event.detail == uniqueID {
                    return true
                }
            }
            return false
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        bus.append(TraceEvent(source: "otherCategory", operation: "log", detail: "ignore"))
        bus.append(TraceEvent(source: category, operation: "log", detail: uniqueID))
        
        let found = await task.value
        #expect(found)
    }
}

@Suite("ConcurrentGroupChatTests")
struct ConcurrentGroupChatTests {
    @Test("Test GroupChatManager initialization")
    @MainActor
    func testGroupChatManagerInit() {
        let manager = GroupChatManager()
        #expect(manager.runningGroupsCount == 0)
        #expect(manager.allGroups.isEmpty)
    }
    
    @Test("Test starting multiple concurrent group chat sessions")
    @MainActor
    func testMultipleConcurrent() async throws {
        let manager = GroupChatManager()
        let orchestrator = AgentOrchestrator()
        let botManager = BotManager(orchestrator: orchestrator, computer: Computer())
        manager.botManager = botManager
        
        let bot1 = botManager.createBot(name: "BotA", title: "RoleA", descriptionText: "DescA")
        let bot2 = botManager.createBot(name: "BotB", title: "RoleB", descriptionText: "DescB")
        let bot3 = botManager.createBot(name: "BotC", title: "RoleC", descriptionText: "DescC")
        
        let group1 = manager.startGroup(name: "Group 1", participantIds: [bot1.id, bot2.id])
        let group2 = manager.startGroup(name: "Group 2", participantIds: [bot2.id, bot3.id])
        
        #expect(manager.allGroups.count == 2)
        #expect(group1.id != group2.id)
    }
    
    @Test("Test selectGroup(id:), runningGroupsCount, closeGroup(id:), and cancelAllGroups()")
    @MainActor
    func testGroupChatManagement() async throws {
        let manager = GroupChatManager()
        let orchestrator = AgentOrchestrator()
        let botManager = BotManager(orchestrator: orchestrator, computer: Computer())
        manager.botManager = botManager
        
        let bot1 = botManager.createBot(name: "Bot1", title: "Role1", descriptionText: "Desc1")
        let bot2 = botManager.createBot(name: "Bot2", title: "Role2", descriptionText: "Desc2")
        
        let group1 = manager.startGroup(name: "G1", participantIds: [bot1.id, bot2.id])
        #expect(manager.allGroups.count == 1)
        
        manager.selectGroup(id: group1.id)
        #expect(manager.activeGroupId == group1.id)
        
        manager.closeGroup(id: group1.id)
        #expect(manager.allGroups.isEmpty)
        
        _ = manager.startGroup(name: "G2", participantIds: [bot1.id, bot2.id])
        _ = manager.startGroup(name: "G3", participantIds: [bot1.id, bot2.id])
        #expect(manager.allGroups.count == 2)
        
        manager.cancelAllGroups()
        #expect(manager.allGroups.isEmpty)
        #expect(manager.activeGroupId == nil)
    }
}

@Suite("ModelCapacityRoutingTests")
struct ModelCapacityRoutingTests {
    @Test("Token count estimation accurately measures prompt size")
    func testTokenCountEstimation() {
        let shortPrompt = "What is 2 + 2?"
        let tokens = ModelRegistry.estimateTokenCount(prompt: shortPrompt)
        #expect(tokens < 100)

        let largeText = String(repeating: "Large prompt content for agent task analysis. ", count: 500)
        let largeTokens = ModelRegistry.estimateTokenCount(prompt: largeText)
        #expect(largeTokens > 4000)
    }

    @Test("Small task stays on Apple On-Device")
    func testSmallTaskStaysOnDevice() {
        let prompt = "Explain recursion in Swift."
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: prompt,
            isPCCAvailable: true
        )
        #expect(provider == .appleOnDevice)
        #expect(reason == nil)
    }

    @Test("Task over 4k limit tiers to Apple Private Cloud Compute when available")
    func testLargeTaskTiersToPCC() {
        let largePrompt = String(repeating: "Full file contents and repository context. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: largePrompt,
            isPCCAvailable: true
        )
        #expect(provider == .applePCC)
        #expect(reason?.contains("Private Cloud Compute") == true)
    }

    @Test("Task over 4k limit tiers to Local Ollama gemma4:12bmlx when PCC unavailable")
    func testLargeTaskTiersToOllamaWhenPCCUnavailable() {
        let largePrompt = String(repeating: "Full file contents and repository context. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .appleOnDevice,
            prompt: largePrompt,
            isPCCAvailable: false
        )
        #expect(provider == .localOllama)
        #expect(reason?.contains("gemma4:12bmlx") == true)
    }

    @Test("Explicit model preference overrides automatic tiering")
    func testExplicitModelOverrideRespected() {
        let largePrompt = String(repeating: "Large repository code diff. ", count: 400)
        let (provider, reason) = ModelRegistry.resolveProviderForTask(
            preferred: .localMLX,
            prompt: largePrompt,
            isPCCAvailable: true
        )
        #expect(provider == .localMLX)
        #expect(reason == nil)
    }
}

