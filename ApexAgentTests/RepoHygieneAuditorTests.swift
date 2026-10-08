import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 31 — Pre-Push Fast Hygiene & Security Gate Tests", .serialized)
struct RepoHygieneAuditorTests {

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Secret scanner detects API keys, GitHub PATs, AWS keys, and PEM private keys while ignoring clean code")
    func secretScannerDetectsCredentialLeaks() {
        let fakeOpenAIKey = "sk-" + "proj-" + String(repeating: "aB9", count: 10)
        let fakeGitHubPAT = "ghp_" + String(repeating: "x7Z", count: 13)
        let fakePEM = "-----BEGIN " + "RSA PRIVATE KEY-----"

        let sample = """
        import Foundation
        let cleanVariable = "normal_value"
        let leaked1 = "\(fakeOpenAIKey)"
        let leaked2 = "\(fakeGitHubPAT)"
        // \(fakePEM)
        """

        let findings = RepoHygieneAuditor.scanForSecrets(in: sample, filePath: "ApexAgent/Sample.swift")
        #expect(findings.count == 3)
        #expect(findings.allSatisfy { $0.category == .leakedSecret })
        #expect(findings.map(\.line) == [3, 4, 5])

        let cleanFindings = RepoHygieneAuditor.scanForSecrets(
            in: "let model = \"gemini-2.5-pro\"\nlet host = \"localhost:11434\"",
            filePath: "ApexAgent/Clean.swift"
        )
        #expect(cleanFindings.isEmpty)
    }

    @Test("Vendor name scanner flags forbidden product names and allows ollama/gemini")
    func vendorNameScannerDetectsForbiddenNames() {
        let badWord1 = "Gr" + "okBotParity"
        let badWord2 = "her" + "mesBridge"
        let source = """
        struct \(badWord1) {}
        let bridge = "\(badWord2)"
        let allowed = "ollama and gemini are valid provider integrations"
        """

        let findings = RepoHygieneAuditor.scanForVendorNames(in: source, filePath: "ApexAgent/TestFile.swift")
        #expect(findings.count == 2)
        #expect(findings[0].category == .forbiddenVendorName)
        #expect(findings[0].line == 1)
        #expect(findings[1].line == 2)
    }

    @Test("Raw print() scanner catches shipping print calls and ignores comments, string literals, and allowlisted files")
    func rawPrintScannerCatchesShippingRegressions() {
        let code = """
        // print("commented out debug line")
        let ruleMessage = "Do not call print( in shipping code"
        AppLog.info(.app, "Structured log entry")
        print("oops leaked stdout")
        """

        let findings = RepoHygieneAuditor.scanForRawPrintCalls(in: code, filePath: "ApexAgent/Models/SomeService.swift")
        #expect(findings.count == 1)
        #expect(findings.first?.category == .rawPrintCall)
        #expect(findings.first?.line == 4)

        // Allowlisted bootstrap banner file should produce zero findings
        let allowlisted = RepoHygieneAuditor.scanForRawPrintCalls(in: code, filePath: "ApexAgent/Models/ApexGatewayServer.swift")
        #expect(allowlisted.isEmpty)
    }

    @Test("PropertyList validator and XcodeGen drift detector catch corrupt plists and unregistered Swift files")
    func propertyListAndXcodeprojDriftValidation() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApexRepoHygieneTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let appDir = tempDir.appendingPathComponent("ApexAgent", isDirectory: true)
        let resDir = appDir.appendingPathComponent("Resources", isDirectory: true)
        let projDir = tempDir.appendingPathComponent("ApexAgent.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: resDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projDir, withIntermediateDirectories: true)

        // Write corrupt Info.plist
        try Data("<<<not xml>>>".utf8).write(to: appDir.appendingPathComponent("Info.plist"))
        // Write valid entitlements
        let validPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>com.apple.security.network.client</key><true/></dict></plist>
        """
        try Data(validPlist.utf8).write(to: appDir.appendingPathComponent("ApexAgent.entitlements"))
        // Missing PrivacyInfo.xcprivacy

        let plistFindings = RepoHygieneAuditor.validatePropertyLists(atRepoRoot: tempDir)
        #expect(plistFindings.count == 2)
        #expect(plistFindings.allSatisfy { $0.category == .invalidPropertyList })

        // Create an unregistered Swift file and a pbxproj that doesn't mention it
        try Data("struct Unregistered {}".utf8).write(to: appDir.appendingPathComponent("UnregisteredFile.swift"))
        try Data("// !$*UTF8*$!\n{\n}\n".utf8).write(to: projDir.appendingPathComponent("project.pbxproj"))

        let driftFindings = RepoHygieneAuditor.checkXcodeprojSync(atRepoRoot: tempDir)
        #expect(driftFindings.count == 1)
        #expect(driftFindings.first?.category == .xcodeprojDrift)
        #expect(driftFindings.first?.file == "ApexAgent/UnregisteredFile.swift")
    }

    @Test("Live repository passes full RepoHygieneAuditor security and hygiene gate with zero findings")
    func liveRepositoryPassesFullAudit() {
        let root = repoRootURL()
        let report = RepoHygieneAuditor.auditRepository(at: root)
        #expect(report.checkedFileCount > 200)
        #expect(report.findings.isEmpty, "Unexpected hygiene findings: \(report.formatSummary())")
        #expect(report.passed)
        #expect(report.formatSummary().hasPrefix("PASS:"))
    }
}
