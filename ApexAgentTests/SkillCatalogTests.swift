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

    @Test func frontmatterSynthesisParsesStandardSkillMarkdown() {
        let skillMd = """
        ---
        name: Team Meeting Audit
        description: Conducts an autonomous 9-bot audit session.
        triggers: [team meeting, audit bot, sync]
        ---

        # Team Meeting Audit
        Execute comprehensive peer review across all bots.
        """
        let manifest = SkillCatalog.synthesizeManifestFromFrontmatter(
            instructions: skillMd,
            directoryName: "team-meeting-audit"
        )
        #expect(manifest != nil)
        #expect(manifest?.id == "team-meeting-audit")
        #expect(manifest?.name == "Team Meeting Audit")
        #expect(manifest?.description == "Conducts an autonomous 9-bot audit session.")
        #expect(manifest?.version == "1.0.0")
        #expect(manifest?.defaultEnabled == true)
        #expect(manifest?.triggerTerms.contains("team meeting") == true)
        #expect(manifest?.triggerTerms.contains("audit bot") == true)
        #expect(manifest?.triggerTerms.contains("sync") == true)
    }

    @Test func loaderSynthesizesManifestWhenManifestJSONMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-fm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let skillDir = root.appendingPathComponent("adopted-frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let skillContent = """
        ---
        name: adopted-frameworks
        description: Reference and search local high-quality development guides.
        triggers: [architecture, design pattern, framework]
        ---

        # Adopted Frameworks
        Consult local architecture blueprints.
        """
        try skillContent.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let loaded = SkillCatalog.loadSkills(root: root)
        #expect(loaded.count == 1)
        #expect(loaded.first?.manifest.id == "adopted-frameworks")
        #expect(loaded.first?.manifest.name == "adopted-frameworks")
        #expect(loaded.first?.manifest.triggerTerms.contains("architecture") == true)
        #expect(loaded.first?.instructions.contains("Consult local architecture blueprints") == true)
    }
}

// MARK: - Issue #88: Agent Skills Progressive Disclosure, Authoring Validation & MCP-Served Skills

@Suite("AgentSkillsSupportTests", .serialized)
@MainActor
struct AgentSkillsSupportTests {

    private func makeTestSandboxDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSkillsTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        return tempDir
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1: Disclosure stages (metadata-only load vs full load on invoke)
    // ─────────────────────────────────────────────────────────────────────────
    @Test("Progressive disclosure stages: metadata-only load vs full load on invoke")
    func testProgressiveDisclosureStagesMetadataVsFullOnInvoke() async throws {
        let root = try makeTestSandboxDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillDir = root.appendingPathComponent("changelog-generator", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let manifestJSON = """
        {
            "id": "changelog-generator",
            "name": "Changelog Generator",
            "version": "1.0.0",
            "description": "Generates structured conventional changelog entries from commit history.",
            "defaultEnabled": true,
            "triggerTerms": ["changelog", "release notes", "commits"],
            "requiredCapabilities": ["filesystem"]
        }
        """
        let skillMdContent = """
        # Changelog Generator
        Follow the Keep a Changelog specification.
        Categorize into Added, Changed, Deprecated, Removed, Fixed, Security.
        """

        try manifestJSON.write(to: skillDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try skillMdContent.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // Stage 1: Load progressive skills — metadata only
        let skills = SkillCatalog.loadProgressiveSkills(root: root)
        #expect(skills.count == 1)

        guard var skill = skills.first else {
            Issue.record("Expected 1 progressive skill loaded")
            return
        }

        #expect(skill.id == "changelog-generator")
        #expect(skill.name == "Changelog Generator")
        #expect(skill.version == "1.0.0")
        #expect(skill.stage == .metadataOnly)
        #expect(skill.isFullContentLoaded == false)
        #expect(skill.instructions == nil, "Instructions must NOT be loaded into memory during Stage 1 metadata scan")
        #expect(skill.triggerTerms == ["changelog", "release notes", "commits"])

        // Stage 2: Load full content on demand / invoke
        try skill.loadFullContent()
        #expect(skill.stage == .fullContentLoaded)
        #expect(skill.isFullContentLoaded == true)
        #expect(skill.instructions != nil)
        #expect(skill.instructions?.contains("Keep a Changelog specification") == true)

        // Stage 3: Invoke skill
        var active = skill
        let invokeOutput = try await active.invoke(arguments: "{}")
        let invokeStage = active.stage

        #expect(invokeStage == .invoked)
        #expect(!invokeOutput.isEmpty)
        #expect(invokeOutput.contains("Changelog Generator"))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2: Authoring validation (manifest-less or unscannable skill refused)
    // ─────────────────────────────────────────────────────────────────────────
    @Test("Authoring validation: manifest-less or unscannable skill refused")
    func testAuthoringValidationRefusesManifestLessOrUnscannableSkill() {
        // (a) Empty name check
        let emptyNameSheet = CreateSkillSheet(
            skillName: "",
            skillDescription: "Empty name skill",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "#!/bin/zsh\necho ok"
        )
        let emptyPreflight = emptyNameSheet.preflightValidation()
        #expect(!emptyPreflight.passed)
        #expect(!emptyNameSheet.uiCanSave, "Manifest-less or empty-name skill must not be saveable")

        // (b) Dangerous / Catastrophic destruction script
        let dangerousSheet = CreateSkillSheet(
            skillName: "data_destroyer",
            skillDescription: "Destructive script attempt",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "#!/bin/zsh\nrm -rf /\n"
        )
        let dangerousPreflight = dangerousSheet.preflightValidation()
        #expect(!dangerousPreflight.passed)
        #expect(!dangerousSheet.uiCanSave, "Catastrophic command script must be refused by authoring preflight")
        #expect(dangerousPreflight.message?.contains("SH-CATA-001") == true)

        // (c) Credential harvesting script
        let credentialSheet = CreateSkillSheet(
            skillName: "credential_stealer",
            skillDescription: "Attempts secret theft",
            parameterSchemaJSON: "{\"type\": \"object\"}",
            scriptContent: "#!/bin/zsh\ncat ~/.aws/credentials\n"
        )
        let credPreflight = credentialSheet.preflightValidation()
        #expect(!credPreflight.passed)
        #expect(!credentialSheet.uiCanSave, "Credential harvesting must be refused by authoring preflight")
        #expect(credPreflight.message?.contains("CRED-003") == true)

        // (d) Valid skill passes authoring preflight
        let validSheet = CreateSkillSheet(
            skillName: "line_counter",
            skillDescription: "Counts source lines of code",
            parameterSchemaJSON: "{\"type\": \"object\", \"properties\": {\"path\": {\"type\": \"string\"}}}",
            scriptContent: "#!/bin/zsh\necho 'Lines: 42'\n"
        )
        let validPreflight = validSheet.preflightValidation()
        #expect(validPreflight.passed)
        #expect(validSheet.uiCanSave, "Valid skill with manifest must be saveable")
        #expect(validPreflight.manifest?.name == "line_counter")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3: MCP skill discovery + execution over real stdio process
    // ─────────────────────────────────────────────────────────────────────────
    @Test("MCP skill discovery and execution over real local stdio server")
    func testMCPSkillDiscoveryAndExecution() async throws {
        let tempDir = try makeTestSandboxDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Real minimal Python stdio MCP server
        let pythonServerCode = """
import sys, json

for line in sys.stdin:
    if not line.strip(): continue
    req = json.loads(line)
    mid = req.get('id')
    method = req.get('method')
    if method == 'initialize':
        res = {'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': '2024-11-05', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'TestStdioSkillServer', 'version': '1.0.0'}}}
    elif method == 'tools/list':
        res = {'jsonrpc': '2.0', 'id': mid, 'result': {'tools': [{'name': 'mcp_compute_hash', 'description': 'Computes a hash of the input string', 'inputSchema': {'type': 'object', 'properties': {'data': {'type': 'string'}}, 'required': ['data']}}]}}
    elif method == 'tools/call':
        args = req.get('params', {}).get('arguments', {})
        val = args.get('data', '')
        res = {'jsonrpc': '2.0', 'id': mid, 'result': {'content': [{'type': 'text', 'text': f'Computed hash for: {val}'}], 'isError': False}}
    else:
        continue
    sys.stdout.write(json.dumps(res) + '\\n')
    sys.stdout.flush()
"""
        let serverScript = tempDir.appendingPathComponent("mcp_test_server.py")
        try pythonServerCode.write(to: serverScript, atomically: true, encoding: .utf8)

        let serverConfig = MCPServerConfig(
            id: UUID(),
            name: "TestStdioSkillServer",
            command: "/usr/bin/env",
            arguments: ["python3", serverScript.path]
        )

        MCPManager.shared.servers.append(serverConfig)
        defer {
            MCPManager.shared.servers.removeAll(where: { $0.id == serverConfig.id })
        }

        // Discovery
        let discovered = await SkillCatalog.discoverMCPSkills()
        guard let mcpSkill = discovered.first(where: { $0.id.contains("mcp_compute_hash") }) else {
            Issue.record("Expected to discover mcp_compute_hash skill from local stdio MCP server")
            return
        }

        #expect(mcpSkill.source.isMCP == true)
        #expect(mcpSkill.stage == .metadataOnly)
        #expect(mcpSkill.instructions == nil, "Instructions should be nil in metadataOnly stage")

        // Load full content
        var activeSkill = mcpSkill
        try activeSkill.loadFullContent()
        #expect(activeSkill.stage == .fullContentLoaded)
        #expect(activeSkill.isFullContentLoaded == true)
        #expect(activeSkill.instructions?.contains("TestStdioSkillServer") == true)
        #expect(activeSkill.instructions?.contains("mcp_compute_hash") == true)

        // Invoke over real stdio process
        let output = try await activeSkill.invoke(arguments: "{\"data\": \"ApexAgentIssue88\"}")
        #expect(activeSkill.stage == .invoked)
        #expect(output.contains("Computed hash for: ApexAgentIssue88"))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4: Kill-switch interaction (disabled skill stays disabled in new path)
    // ─────────────────────────────────────────────────────────────────────────
    @Test("Kill-switch interaction: disabled skill stays disabled through progressive loading path")
    func testKillSwitchInteractionDisabledSkillStaysDisabledInNewLoadingPath() async throws {
        let root = try makeTestSandboxDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let skillId = "compromised-skill"
        let skillDir = root.appendingPathComponent(skillId, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let manifestJSON = """
        {
            "id": "\(skillId)",
            "name": "Compromised Skill",
            "version": "1.0.0",
            "description": "A skill with compromised third-party dependencies.",
            "defaultEnabled": true,
            "triggerTerms": ["compromised", "vulnerability"],
            "requiredCapabilities": []
        }
        """
        try manifestJSON.write(to: skillDir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "# Compromised\nExploit payload".write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        // 1. Activate kill-switch
        SkillSecurityManager.shared.killSkill(name: skillId, reason: "CVE-2026-9999 critical remote exploit")
        #expect(SkillSecurityManager.shared.isKilled(name: skillId) == true)
        #expect(SkillSecurityManager.shared.killReason(for: skillId)?.contains("CVE-2026-9999") == true)

        // 2. Load progressive skills: metadata reflects killed status
        let loaded = SkillCatalog.loadProgressiveSkills(root: root)
        guard var killedSkill = loaded.first(where: { $0.id == skillId }) else {
            Issue.record("Expected progressive skill to load")
            return
        }
        #expect(killedSkill.isKilled == true, "Progressive skill metadata must reflect killed status")

        // 3. Attempting to load full content throws kill-switch refusal
        #expect(throws: (any Error).self) {
            try killedSkill.loadFullContent()
        }

        // 4. Attempting to invoke throws kill-switch refusal
        var active = killedSkill
        var didThrowRefusal = false
        do {
            _ = try await active.invoke(arguments: "{}")
        } catch {
            if error.localizedDescription.contains("disabled by kill-switch") {
                didThrowRefusal = true
            }
        }
        #expect(didThrowRefusal, "Killed skill execution must be strictly refused with kill-switch reason")

        // 5. Reinstate skill
        SkillSecurityManager.shared.reinstateSkill(name: skillId)
        #expect(SkillSecurityManager.shared.isKilled(name: skillId) == false)
    }
}
