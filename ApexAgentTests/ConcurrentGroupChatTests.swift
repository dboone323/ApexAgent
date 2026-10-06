import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

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
