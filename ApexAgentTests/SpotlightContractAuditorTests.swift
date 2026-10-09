import Foundation
import Testing
import CoreSpotlight
@testable import ApexAgentCore

@Suite("Spotlight Search Contract Auditor Tests")
struct SpotlightContractAuditorTests {
    @Test("Audits standard SpotlightIndexer items with zero violations and full score")
    func compliantSpotlightItemsAudit() {
        let conversationItem = SpotlightIndexer.makeConversationItem(
            id: UUID(),
            title: "Swift 6 Concurrency Refactor",
            messages: [("user", "Help migrate actor code"), ("assistant", "Here is the plan")],
            updatedAt: Date()
        )

        let routineItem = SpotlightIndexer.makeRoutineItem(
            id: "daily-hygiene",
            name: "Daily Repo Hygiene",
            descriptionText: "Runs lint and security tests every morning",
            trigger: "cron"
        )

        let skillItem = SpotlightIndexer.makeSkillItem(
            name: "git-commit-helper",
            description: "Creates conventional git commits automatically"
        )

        let commandItem = SpotlightIndexer.makeSlashCommandItem(
            name: "/doctor",
            summary: "Unified system doctor diagnosis"
        )

        let report = SpotlightContractAuditor.auditItems([
            conversationItem,
            routineItem,
            skillItem,
            commandItem
        ])

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.auditedItems == 4)
        #expect(report.validDomainsCount == 4)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("100.0/100.0"))
    }

    @Test("Detects unregistered domain identifier as critical violation")
    func unregisteredDomainAudit() {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = "Unknown Domain Item"
        attrs.contentDescription = "Random item"
        attrs.keywords = ["test"]
        let item = CSSearchableItem(
            uniqueIdentifier: "item-rogue-01",
            domainIdentifier: "com.rogue.unregistered.domain",
            attributeSet: attrs
        )

        let violations = SpotlightContractAuditor.auditItem(item)
        let hasDomainViolation = violations.contains { $0.ruleId == "spotlight_unregistered_domain" }
        #expect(hasDomainViolation)
    }

    @Test("Detects missing title and empty keywords")
    func missingTitleAndKeywordsAudit() {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = "   " // blank title
        attrs.contentDescription = "Valid description"
        attrs.keywords = [] // empty keywords
        attrs.contentURL = URL(string: "apexagent://chat/1234")

        let item = CSSearchableItem(
            uniqueIdentifier: "session-missing-fields",
            domainIdentifier: SpotlightIndexer.domainIdentifier,
            attributeSet: attrs
        )

        let violations = SpotlightContractAuditor.auditItem(item)
        let hasTitleViolation = violations.contains { $0.ruleId == "spotlight_missing_title" }
        #expect(hasTitleViolation)
        let hasKeywordsViolation = violations.contains { $0.ruleId == "spotlight_empty_keywords" }
        #expect(hasKeywordsViolation)
    }

    @Test("Detects invalid contentURL scheme")
    func invalidURLSchemeAudit() {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = "Valid Title"
        attrs.contentDescription = "Valid description"
        attrs.keywords = ["ApexAgent", "routine"]
        attrs.contentURL = URL(string: "https://external-website.com/routine/1")

        let item = CSSearchableItem(
            uniqueIdentifier: "routine-bad-url",
            domainIdentifier: SpotlightIndexer.routinesDomainIdentifier,
            attributeSet: attrs
        )

        let violations = SpotlightContractAuditor.auditItem(item)
        let hasSchemeViolation = violations.contains { $0.ruleId == "spotlight_invalid_url_scheme" }
        #expect(hasSchemeViolation)
    }

    @Test("Detects missing deep link for command domain")
    func missingDeepLinkAudit() {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = "Command without link"
        attrs.contentDescription = "Description"
        attrs.keywords = ["command"]
        // contentURL intentionally omitted

        let item = CSSearchableItem(
            uniqueIdentifier: "command-no-link",
            domainIdentifier: SpotlightIndexer.commandsDomainIdentifier,
            attributeSet: attrs
        )

        let violations = SpotlightContractAuditor.auditItem(item)
        let hasMissingLink = violations.contains { $0.ruleId == "spotlight_missing_deeplink_url" }
        #expect(hasMissingLink)
    }
}
