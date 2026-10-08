import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 39 — Entitlements, Weak-Linked Frameworks & Build-Graph Parity Verifier Tests")
struct BundleIntegrityVerifierTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository entitlements, Info.plist, Package.swift, and project.yml pass bundle integrity audit")
    func liveRepositoryBundleIntegrityPasses() {
        let report = BundleIntegrityVerifier.verifyRepositoryBundleIntegrity(atRepoRoot: repoRoot)
        #expect(report.passed, "\(report.formatSummary())")
        #expect(report.issues.isEmpty)
        #expect(report.formatSummary().hasPrefix("PASS:"))
    }

    @Test("Verifier catches weakened entitlements, missing apexagent:// URL scheme, and missing weak_framework flags")
    func detectsEntitlementInfoPlistAndBuildGraphDrift() {
        let badEntitlementsXML = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.app-sandbox</key>
            <true/>
            <key>com.apple.security.cs.allow-jit</key>
            <true/>
            <key>com.apple.security.virtualization</key>
            <false/>
        </dict>
        </plist>
        """.utf8)
        let entIssues = BundleIntegrityVerifier.validateEntitlementsPlist(badEntitlementsXML)
        #expect(entIssues.contains { $0.kind == .unexpectedEntitlementValue && $0.message.contains("virtualization") })
        #expect(entIssues.contains { $0.kind == .unexpectedEntitlementValue && $0.message.contains("allow-jit") })
        #expect(entIssues.contains { $0.kind == .missingRequiredEntitlement && $0.message.contains("group.com.apexagent") })

        let badInfoPlistXML = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>Apex Agent</string>
        </dict>
        </plist>
        """.utf8)
        let infoIssues = BundleIntegrityVerifier.validateInfoPlist(badInfoPlistXML)
        #expect(infoIssues.contains { $0.kind == .missingURLSchemeRegistration })
        #expect(infoIssues.contains { $0.kind == .missingInfoPlistKey })

        let buildIssues = BundleIntegrityVerifier.validateBuildGraphParity(
            packageSwift: "let package = Package(name: \"Incomplete\")",
            projectYML: "name: Incomplete"
        )
        #expect(buildIssues.contains { $0.kind == .missingWeakFrameworkFlag && $0.message.contains("FoundationModels") })
        #expect(buildIssues.contains { $0.kind == .missingRpathOrSigningConfig })
    }

    @Test("ApexCLIRouter.runDoctor includes passing dependency_lock and bundle_integrity checks")
    func doctorIncludesDependencyLockAndBundleIntegrityChecks() {
        let report = ApexCLIRouter.runDoctor()
        let depCheck = report.checks.first { $0.id == "dependency_lock" }
        let bundleCheck = report.checks.first { $0.id == "bundle_integrity" }
        #expect(depCheck?.passed == true)
        #expect(bundleCheck?.passed == true)
    }
}
