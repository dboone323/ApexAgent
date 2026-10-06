import Testing
import Foundation
@testable import ApexAgentCore

@Suite("HardeningLoopBatch15Tests")
struct HardeningLoopBatch15Tests {
    @Test @MainActor func testEpisodicEntry() {
        let e = CognitiveMemoryEngine.EpisodicEntry(botId: UUID(), eventType: "tool_call", summary: "ran ls")
        #expect(e.isWellFormed)
        #expect(e.formatAsMarkdown().contains("tool_call"))
        let bad = CognitiveMemoryEngine.EpisodicEntry(botId: UUID(), eventType: "  ", summary: "")
        #expect(!bad.isWellFormed)
    }

    @Test func testSkillValidationBadges() {
        #expect(SkillValidationError.fileNotFound("x").badge.contains("Missing"))
        #expect(SkillValidationError.invalidJSON("x").formatAsMarkdown().contains("Bad JSON"))
    }

    @Test func testKeychainAuditMarkdown() {
        let entry = KeychainAuditEntry(operation: "get", key: "svc", success: true)
        #expect(entry.operationBadge.contains("Read"))
        #expect(entry.formatAsMarkdown().contains("svc"))
    }

    @Test func testSkillManifestPreflight() {
        let ok = SkillManifestInfo(name: "n", description: "d", scriptPath: "/tmp/x.sh", parameterCount: 1)
        #expect(ok.preflightError() == nil)
        #expect(ok.isPreflightClean)
        let bad = SkillManifestInfo(name: "", description: "", scriptPath: "", parameterCount: -1)
        #expect(bad.preflightError() != nil)
        #expect(!bad.isPreflightClean)
    }
}
