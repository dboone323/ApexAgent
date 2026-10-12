//
//  NotionIntegrationAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 115: Notion API Block & Database Property Builder with Schema Auditor Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 115 — Notion API Block & Database Integration Tests")
struct NotionIntegrationAuditorTests {

    @Test("Valid Notion integration key and version pass audit with 100% score")
    func testValidNotionAuditConfiguration() {
        let report = NotionIntegrationAuditor.auditConfiguration(
            apiKey: "secret_auditTestKey123",
            notionVersion: "2022-06-28"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.notionVersion == "2022-06-28")
        #expect(report.redactedKey?.contains("...") == true)
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP transport and empty API key trip fatal violations")
    func testInsecureAndEmptyKeyTripViolations() {
        let report = NotionIntegrationAuditor.auditConfiguration(
            apiKey: "",
            notionVersion: "2022-06-28",
            endpointURL: URL(string: "http://api.notion.com/v1")!
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "EMPTY_NOTION_API_KEY" }))
        #expect(report.violations.contains(where: { $0.code == "INSECURE_NOTION_HTTP_ENDPOINT" }))
    }

    @Test("buildMarkdownToBlocks converts markdown syntax to Notion block schemas")
    func testBuildMarkdownToBlocks() {
        let markdown = """
        # Main Title
        ## Subtitle
        ### Small Section
        - Bullet point one
        - Bullet point two
        ---
        ```swift
        print("Hello")
        ```
        Regular prose paragraph.
        """

        let blocks = NotionIntegrationAuditor.buildMarkdownToBlocks(markdown: markdown)
        #expect(blocks.count >= 7)

        #expect(blocks[0]["type"] as? String == "heading_1")
        #expect(blocks[1]["type"] as? String == "heading_2")
        #expect(blocks[2]["type"] as? String == "heading_3")
        #expect(blocks[3]["type"] as? String == "bulleted_list_item")
        #expect(blocks[5]["type"] as? String == "divider")
        #expect(blocks[6]["type"] as? String == "code")
    }

    @Test("buildCreatePageRequest builds valid Notion REST request with database parent and properties")
    func testBuildCreatePageRequest() throws {
        let payload = NotionPageCreatePayload(
            databaseId: "db_1234567890abcdef",
            title: "Autonomous Agent Incident Report",
            status: "Resolved",
            tags: ["security", "audit"],
            contentMarkdown: "### Incident Summary\nAll subsystems restored."
        )

        let req = NotionIntegrationAuditor.buildCreatePageRequest(
            apiKey: "secret_auditTestKey123",
            payload: payload
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/pages")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_auditTestKey123")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2022-06-28")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]

        let parent = bodyJson?["parent"] as? [String: String]
        #expect(parent?["database_id"] == "db_1234567890abcdef")

        let properties = bodyJson?["properties"] as? [String: Any]
        let titleObj = properties?["title"] as? [String: Any]
        let titleArr = titleObj?["title"] as? [[String: Any]]
        let textObj = titleArr?[0]["text"] as? [String: String]
        #expect(textObj?["content"] == "Autonomous Agent Incident Report")

        let children = bodyJson?["children"] as? [[String: Any]]
        #expect(children?.count == 2)
    }

    @Test("buildAppendBlockChildrenRequest creates PATCH request for block children endpoint")
    func testBuildAppendBlockChildrenRequest() throws {
        let block: [String: Any] = [
            "object": "block",
            "type": "paragraph",
            "paragraph": ["rich_text": [["type": "text", "text": ["content": "New line"]]]]
        ]

        let req = NotionIntegrationAuditor.buildAppendBlockChildrenRequest(
            apiKey: "secret_auditTestKey123",
            blockId: "block_999",
            blocks: [block]
        )

        let request = try #require(req)
        #expect(request.httpMethod == "PATCH")
        #expect(request.url?.absoluteString == "https://api.notion.com/v1/blocks/block_999/children")

        let bodyData = try #require(request.httpBody)
        let bodyJson = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let children = bodyJson?["children"] as? [[String: Any]]
        #expect(children?.count == 1)
    }

    @Test("formatNotionAuditReportMarkdown produces clean markdown table")
    func testMarkdownFormatting() {
        let report = NotionIntegrationAuditor.auditConfiguration(
            apiKey: "secret_auditTestKey123",
            notionVersion: "2022-06-28"
        )

        let md = NotionIntegrationAuditor.formatNotionAuditReportMarkdown(report)
        #expect(md.contains("Notion API Block & Database Integration Audit"))
        #expect(md.contains("2022-06-28"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
