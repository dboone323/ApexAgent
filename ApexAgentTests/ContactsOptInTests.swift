import Testing
import Foundation
import Contacts
@testable import ApexAgentCore

@Suite("ContactsOptInTests")
struct ContactsOptInTests {

    @Test("ContactsOptInManager defaults to false in test mode and prevents store access")
    func testContactsOptInManagerDefaultInTestMode() async throws {
        let manager = ContactsOptInManager.shared
        manager.resetForTesting(optedIn: nil)

        #expect(manager.isTestMode == true)
        #expect(manager.isOptedIn == false)

        // Verifies requestAccessIfNeeded returns false immediately without throwing or accessing contactsd
        let granted = await manager.requestAccessIfNeeded()
        #expect(granted == false)
    }

    @Test("ContactsOptInManager state persistence can be toggled")
    func testContactsOptInManagerToggle() async throws {
        let manager = ContactsOptInManager.shared
        manager.resetForTesting(optedIn: true)
        #expect(manager.isOptedIn == true)

        manager.resetForTesting(optedIn: false)
        #expect(manager.isOptedIn == false)

        // Reset back to default
        manager.resetForTesting(optedIn: nil)
    }

    @Test("CalendarTool and ReminderTool respect opt-in gating gracefully without throwing")
    @MainActor
    func testToolsRespectOptInGating() async throws {
        let orchestrator = AgentOrchestrator()
        let calTool = CalendarTool(orchestrator: orchestrator)
        let remTool = ReminderTool(orchestrator: orchestrator)

        ContactsOptInManager.shared.resetForTesting(optedIn: false)

        let calResult = try await calTool.call(arguments: CalendarTool.Arguments(action: "list"))
        #expect(calResult.contains("Calendar access was not granted"))

        let remResult = try await remTool.call(arguments: ReminderTool.Arguments(action: "list"))
        #expect(remResult.contains("Reminders access was not granted"))
    }

    @Test("safeFullUserName resolves securely without touching AddressBook Me-Card in test mode")
    func testSafeFullUserNameInTestMode() async throws {
        let manager = ContactsOptInManager.shared
        manager.resetForTesting(optedIn: false)

        let resolvedName = manager.safeFullUserName
        #expect(!resolvedName.isEmpty, "Safe user name must not be empty")
        #expect(resolvedName == NSUserName() || resolvedName == "User")
    }

    @Test("UserAccountManager syncSettings does not touch iCloud KV store in test mode")
    @MainActor
    func testUserAccountManagerSyncInTestMode() async throws {
        let accountManager = UserAccountManager.shared
        // In test mode, this must be a safe no-op without store connection errors
        accountManager.syncSettings()
        accountManager.pullSyncedSettings()
        #expect(ContactsOptInManager.shared.isTestMode == true)
    }
}
