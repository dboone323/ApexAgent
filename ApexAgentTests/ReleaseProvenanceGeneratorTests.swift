import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Release Provenance Generator & Notarization Readiness Tests (Batch 44)")
struct ReleaseProvenanceGeneratorTests {

    private var repoRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Generates real SLSA v1.0 provenance attestation and SHA-256 checksums for repository manifests")
    func generatesLiveRepositorySLSAProvenanceAndChecksums() throws {
        let attestation = ReleaseProvenanceGenerator.generateRepositoryProvenance(atRepoRoot: repoRootURL)
        #expect(attestation.notarizationReport.passed, "Findings: \(attestation.notarizationReport.findings)")
        #expect(attestation.subjects.count == 6)
        #expect(attestation.packageResolvedSHA256.count == 64)
        #expect(!attestation.gitCommitSHA.isEmpty)

        // Verify SHA256SUMS output format (`<64-char-hex>  <path>`)
        let shaSums = attestation.toSHA256SumsText()
        #expect(shaSums.contains("  Package.resolved"))
        #expect(shaSums.contains("  ApexAgent/Info.plist"))

        // Verify SLSA v1.0 JSON schema
        let slsaJSON = attestation.toSLSAJSON()
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(slsaJSON.utf8)) as? [String: Any])
        #expect(parsed["_type"] as? String == "https://in-toto.io/Statement/v1")
        #expect(parsed["predicateType"] as? String == "https://slsa.dev/provenance/v1")
        let subjects = try #require(parsed["subject"] as? [[String: Any]])
        #expect(subjects.count == 6)

        // Verify Markdown output
        #expect(attestation.toMarkdown().contains("SLSA v1.0 Build Provenance & Notarization Readiness (`PASS`)"))
    }

    @Test("Flags com.apple.security.get-task-allow=true when auditing for release Notary distribution")
    func flagsGetTaskAllowInReleaseDistributionMode() {
        let debugEntitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.get-task-allow</key>
            <true/>
        </dict>
        </plist>
        """
        let validInfoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.apexagent.app</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>26.0</string>
        </dict>
        </plist>
        """

        // Allowed in local development mode (`forReleaseDistribution: false`)
        let devReport = ReleaseProvenanceGenerator.auditNotarizationReadiness(
            entitlementsData: Data(debugEntitlements.utf8),
            infoPlistData: Data(validInfoPlist.utf8),
            forReleaseDistribution: false
        )
        #expect(devReport.passed)
        #expect(devReport.getTaskAllowPresent)

        // Blocked in release distribution mode (`forReleaseDistribution: true`)
        let releaseReport = ReleaseProvenanceGenerator.auditNotarizationReadiness(
            entitlementsData: Data(debugEntitlements.utf8),
            infoPlistData: Data(validInfoPlist.utf8),
            forReleaseDistribution: true
        )
        #expect(!releaseReport.passed)
        #expect(releaseReport.findings.contains { $0.contains("get-task-allow") })
    }

    @Test("ApexCLIRouter parses and renders provenance subcommand in Markdown and SLSA JSON")
    @MainActor
    func cliRouterParsesAndRendersProvenance() throws {
        let parsed = try ApexCLIRouter.parse(arguments: ["ApexAgent", "--json", "provenance"])
        #expect(parsed.command == .provenance(jsonOutput: true))

        let jsonOut = try #require(ApexCLIRouter.renderImmediateSubcommand(.provenance(jsonOutput: true)))
        #expect(jsonOut.exitCode == 0)
        #expect(jsonOut.output.contains("https://slsa.dev/provenance/v1"))
    }
}
