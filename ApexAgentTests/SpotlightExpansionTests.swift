import Foundation
import CoreSpotlight
import Testing
@testable import ApexAgentCore

@Suite("Batch 30 — Spotlight Search Expansion & Deep-Link Handoff Tests", .serialized)
struct SpotlightExpansionTests {

    @Test("CSSearchableItemAttributeSet for routines, skills, slash commands, and conversations populates rich attributes and deep-link contentURLs")
    func searchableItemAttributeSetsAndDeepLinks() {
        let routineItem = SpotlightIndexer.makeRoutineItem(
            id: "morning-triage",
            name: "Morning Triage",
            descriptionText: "Summarize unread issues and PRs every weekday at 9am",
            trigger: "cron",
            keywords: ["github", "standup"]
        )
        #expect(routineItem.uniqueIdentifier == "routine-morning-triage")
        #expect(routineItem.domainIdentifier == SpotlightIndexer.routinesDomainIdentifier)
        #expect(routineItem.attributeSet.title == "Routine: Morning Triage")
        #expect(routineItem.attributeSet.contentDescription?.contains("Summarize unread issues") == true)
        #expect(routineItem.attributeSet.keywords?.contains("automation") == true)
        #expect(routineItem.attributeSet.keywords?.contains("github") == true)
        #expect(routineItem.attributeSet.contentURL == URL(string: "apexagent://routine/morning-triage"))

        let skillItem = SpotlightIndexer.makeSkillItem(
            name: "xcodebuild-audit",
            description: "Builds and validates Xcode schemes with xcresult inspection",
            triggerTerms: ["xcodebuild", "xctest", "build"]
        )
        #expect(skillItem.uniqueIdentifier == "skill-xcodebuild-audit")
        #expect(skillItem.domainIdentifier == SpotlightIndexer.skillsDomainIdentifier)
        #expect(skillItem.attributeSet.title == "Skill: xcodebuild-audit")
        #expect(skillItem.attributeSet.keywords?.contains("xctest") == true)
        #expect(skillItem.attributeSet.contentURL == URL(string: "apexagent://skill/xcodebuild-audit"))

        let commandItem = SpotlightIndexer.makeSlashCommandItem(
            name: "/plan",
            summary: "Generate a step-by-step execution plan before modifying files",
            keywords: ["architecture", "design"]
        )
        #expect(commandItem.uniqueIdentifier == "command-plan")
        #expect(commandItem.domainIdentifier == SpotlightIndexer.commandsDomainIdentifier)
        #expect(commandItem.attributeSet.title == "Command: /plan")
        #expect(commandItem.attributeSet.keywords?.contains("/plan") == true)
        #expect(commandItem.attributeSet.contentURL == URL(string: "apexagent://command/plan"))

        let chatUUID = UUID()
        let chatItem = SpotlightIndexer.makeConversationItem(
            id: chatUUID,
            title: "MCP Protocol Upgrade",
            messages: [(role: "user", content: "Upgrade MCP to 2026-07-28")],
            updatedAt: Date()
        )
        #expect(chatItem.uniqueIdentifier == chatUUID.uuidString)
        #expect(chatItem.attributeSet.contentURL == URL(string: "apexagent://chat/\(chatUUID.uuidString)"))
    }

    @Test("Index and remove round-trip for routines, skills, and slash commands via CSSearchableIndex")
    func indexAndRemoveRoundTrip() async {
        let routineId = "test-routine-\(UUID().uuidString)"
        let skillName = "test-skill-\(UUID().uuidString)"
        let commandName = "test-cmd-\(UUID().uuidString)"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.indexRoutine(
                id: routineId,
                name: "Test Routine",
                descriptionText: "Verify CoreSpotlight indexing",
                trigger: "manual"
            ) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "routine-\(routineId)")?.attributeSet.title == "Routine: Test Routine")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.removeRoutine(id: routineId) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "routine-\(routineId)") == nil)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.indexSkill(
                name: skillName,
                description: "Verify skill Spotlight indexing",
                triggerTerms: ["spotlight"]
            ) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "skill-\(skillName)")?.attributeSet.title == "Skill: \(skillName)")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.removeSkill(name: skillName) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "skill-\(skillName)") == nil)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.indexSlashCommand(
                name: commandName,
                summary: "Verify slash command Spotlight indexing"
            ) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "command-\(commandName)")?.attributeSet.title == "Command: /\(commandName)")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SpotlightIndexer.removeSlashCommand(name: commandName) { _ in
                continuation.resume()
            }
        }
        #expect(SpotlightIndexer.indexedItem(forUniqueIdentifier: "command-\(commandName)") == nil)
    }

    @Test("Spotlight result activation routes routine, skill, command, and conversation identifiers into DeepLinkNavigationState")
    @MainActor
    func spotlightActivationHandoffToDeepLinkNavigationState() {
        let navState = DeepLinkNavigationState()

        // 1. Routine activation
        let routineResult = SpotlightIndexer.handleSpotlightActivation(
            uniqueIdentifier: "routine-daily-digest",
            navigationState: navState
        )
        #expect(routineResult == .success(.routine(id: "daily-digest")))
        #expect(navState.selectedRoutineId == "daily-digest")

        // 2. Skill activation
        let skillResult = SpotlightIndexer.handleSpotlightActivation(
            uniqueIdentifier: "skill-security-audit",
            navigationState: navState
        )
        #expect(skillResult == .success(.skill(name: "security-audit")))
        #expect(navState.selectedSkillName == "security-audit")

        // 3. Slash command activation
        let commandResult = SpotlightIndexer.handleSpotlightActivation(
            uniqueIdentifier: "command-boost",
            navigationState: navState
        )
        #expect(commandResult == .success(.command(name: "boost")))
        #expect(navState.lastExecutedCommand == "boost")

        // 4. Conversation UUID activation
        let chatId = UUID().uuidString
        let chatResult = SpotlightIndexer.handleSpotlightActivation(
            uniqueIdentifier: chatId,
            navigationState: navState
        )
        #expect(chatResult == .success(.chat(id: chatId)))
        #expect(navState.activeChatId == chatId)

        // 5. Unknown/empty identifier returns nil safely
        #expect(SpotlightIndexer.handleSpotlightActivation(uniqueIdentifier: "   ", navigationState: navState) == nil)
    }
}
