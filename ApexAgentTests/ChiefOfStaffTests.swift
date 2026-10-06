import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O7: Chief of Staff roster prompt

@Suite("ChiefOfStaffTests")
struct ChiefOfStaffTests {

    private func member(id: String, name: String, section: String? = nil,
                        title: String? = nil, busy: Bool = false, hidden: Bool = false) -> ChiefTeamMember {
        ChiefTeamMember(id: id, name: name, title: title, descriptionText: nil,
                        busy: busy, hidden: hidden, section: section)
    }

    @Test func promptNamesSectionAndListsAvailableTeammates() {
        let bots = [
            member(id: "chief", name: "Chief", section: "Sales"),
            member(id: "a", name: "Prospector", section: "Sales", title: "Outbound", busy: false),
            member(id: "b", name: "Closer", section: "Sales", title: "Deals", busy: true),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(prompt.contains("Chief of Staff for the Sales section"))
        #expect(prompt.contains("- Prospector — Outbound (available)"))
        #expect(prompt.contains("- Closer — Deals (working right now)"))
    }

    @Test func hiddenAndOtherSectionBotsExcluded() {
        let bots = [
            member(id: "chief", name: "Chief", section: "Sales"),
            member(id: "hidden", name: "SecretSquirrel", section: "Sales", hidden: true),
            member(id: "other", name: "OpsPerson", section: "Ops"),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(!prompt.contains("SecretSquirrel"))
        #expect(!prompt.contains("OpsPerson"))
        #expect(prompt.contains("No other visible bots"))
    }

    @Test func longNamesAreClippedToCaps() {
        let longName = String(repeating: "x", count: 200)
        let bots = [
            member(id: "chief", name: "Chief"),
            member(id: "long", name: longName),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(prompt.contains(String(repeating: "x", count: 79) + "…"))
        #expect(!prompt.contains(longName))
    }

    @Test func noDelegationEngineIsHonest() {
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: [], canDelegate: false)
        #expect(prompt.contains("cannot contact teammates"))
        #expect(!prompt.contains("Use ask-bot when a teammate"))
    }
}
