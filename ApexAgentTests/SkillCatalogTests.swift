import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O8: Skill catalog manifests + trigger matching

@Suite("SkillCatalogTests")
struct SkillCatalogTests {

    private func manifestJSON(id: String = "release-notes",
                              version: String = "1.0.0",
                              triggerTerms: [String] = ["release notes", "changelog"],
                              defaultEnabled: Any = true,
                              requiredCapabilities: [String]? = ["filesystem"]) -> [String: Any] {
        [
            "id": id,
            "name": "Release Notes",
            "version": version,
            "description": "Writes release notes from commits",
            "defaultEnabled": defaultEnabled,
            "triggerTerms": triggerTerms,
            "requiredCapabilities": requiredCapabilities as Any,
        ]
    }

    @Test func validManifestParses() throws {
        let manifest = try SkillCatalog.parseManifest(manifestJSON(), directoryName: "release-notes")
        #expect(manifest.id == "release-notes")
        #expect(manifest.triggerTerms.count == 2)
        #expect(manifest.requiredCapabilities == ["filesystem"])
        #expect(manifest.defaultEnabled == true)
    }

    @Test func invalidIdOrVersionRejected() throws {
        let badId = manifestJSON(id: "Bad_Id")
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(badId, directoryName: "bad-id")
        }
        let badVersion = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: [
            "id": "release-notes", "name": "n", "version": "1.0",
            "description": "d", "defaultEnabled": true, "triggerTerms": ["x"],
            "requiredCapabilities": [],
        ])) 
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(badVersion, directoryName: "release-notes")
        }
    }

    @Test func missingTriggerTermsRejected() throws {
        let noTerms = manifestJSON(triggerTerms: [])
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(noTerms, directoryName: "release-notes")
        }
    }

    @Test func loaderIsolatesBrokenFoldersAndLoadsGoodOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let good = root.appendingPathComponent("release-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifestJSON())
            .write(to: good.appendingPathComponent("manifest.json"))
        try "# Release Notes\nWrite them.".write(
            to: good.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let broken = root.appendingPathComponent("broken-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{}".write(to: broken.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let loaded = SkillCatalog.loadSkills(root: root)
        #expect(loaded.count == 1)
        #expect(loaded.first?.manifest.id == "release-notes")
    }

    @Test func triggerMatchingRespectsEnablement() throws {
        let skills: [(manifest: SkillManifest, instructions: String)] = [
            (try SkillCatalog.parseManifest(manifestJSON(), directoryName: "release-notes"), ""),
            (try SkillCatalog.parseManifest(
                manifestJSON(id: "expenses", triggerTerms: ["expense report"], defaultEnabled: false),
                directoryName: "expenses"), ""),
        ]
        let hitRelease = SkillCatalog.matchingSkills(prompt: "please draft release notes", skills: skills)
        #expect(hitRelease.map(\.id) == ["release-notes"])

        // Disabled-by-default skill only matches when explicitly enabled.
        #expect(SkillCatalog.matchingSkills(prompt: "file an expense report", skills: skills).isEmpty)
        let enabled = SkillCatalog.matchingSkills(
            prompt: "file an expense report", skills: skills, enabledIds: ["expenses"])
        #expect(enabled.map(\.id) == ["expenses"])
    }

    @Test func termsRoundTripThroughJSON() {
        let encoded = SkillCatalog.encodeTerms(["release notes", "changelog"])
        #expect(SkillCatalog.decodeTerms(fromJSON: encoded) == ["release notes", "changelog"])
        #expect(SkillCatalog.decodeTerms(fromJSON: "not json") == [])
    }
}
