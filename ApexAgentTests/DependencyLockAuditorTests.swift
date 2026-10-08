import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 36 — Supply-Chain Dependency Pinning & SBOM Auditor Tests")
struct DependencyLockAuditorTests {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test("Live repository Package.resolved, Package.swift, and project.yml pass supply-chain lock audit")
    func liveRepositorySupplyChainAuditPasses() {
        let report = DependencyLockAuditor.auditRepository(atRepoRoot: repoRoot)
        #expect(report.passed, "\(report.formatSummary())")
        #expect(report.violations.isEmpty)
        #expect(report.pins.count >= 20)
        #expect(report.pins.contains { $0.identity == "containerization" && $0.version == "0.38.0" })
        #expect(report.pins.contains { $0.identity == "swift-log" && $0.version == "1.14.0" })
        #expect(report.formatSummary().hasPrefix("PASS:"))
    }

    @Test("Auditor flags HTTP URLs, untrusted orgs, floating branch pins, invalid SHAs, and manifest version drift")
    func detectsSupplyChainViolationsAndManifestDrift() {
        let badPins: [LockedDependencyPin] = [
            LockedDependencyPin(
                identity: "insecure-pkg",
                location: "http://github.com/apple/swift-log.git",
                version: "1.14.0",
                revision: "a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a"
            ),
            LockedDependencyPin(
                identity: "untrusted-pkg",
                location: "https://github.com/untrusted-vendor/evil-pkg.git",
                version: "1.0.0",
                revision: "a878e7f8f46cfc0e1125e565b5c08e7d5272dc9a"
            ),
            LockedDependencyPin(
                identity: "floating-pkg",
                location: "https://github.com/apple/swift-nio.git",
                version: nil,
                revision: "0b18836bd8b0162e7e17a995a3fbee20ed8f3b2b",
                branch: "main"
            ),
            LockedDependencyPin(
                identity: "bad-sha-pkg",
                location: "https://github.com/apple/swift-crypto.git",
                version: "3.15.1",
                revision: "NOT_A_40_CHAR_HEX_SHA"
            )
        ]

        let pinViolations = DependencyLockAuditor.auditPins(badPins)
        #expect(pinViolations.contains { $0.kind == .insecureRepositoryURL && $0.identity == "insecure-pkg" })
        #expect(pinViolations.contains { $0.kind == .untrustedRepositoryOwner && $0.identity == "untrusted-pkg" })
        #expect(pinViolations.contains { $0.kind == .floatingBranchPin && $0.identity == "floating-pkg" })
        #expect(pinViolations.contains { $0.kind == .invalidCommitRevision && $0.identity == "bad-sha-pkg" })

        let driftPins = [
            LockedDependencyPin(
                identity: "containerization",
                location: "https://github.com/apple/containerization.git",
                version: "0.37.0",
                revision: "d9868bb657fac3b55ed5dcec97c8eb8a08e78bf5"
            )
        ]
        let samplePackageSwift = """
        dependencies: [
            .package(url: "https://github.com/apple/containerization.git", exact: "0.38.0"),
        ]
        """
        let sampleProjectYML = """
        packages:
          Containerization:
            url: https://github.com/apple/containerization
            exactVersion: 0.36.0
        """
        let parityViolations = DependencyLockAuditor.auditManifestParity(
            pins: driftPins,
            packageSwift: samplePackageSwift,
            projectYML: sampleProjectYML
        )
        #expect(parityViolations.count == 2)
        #expect(parityViolations.allSatisfy { $0.kind == .manifestVersionMismatch })
    }

    @Test("CycloneDX 1.5 JSON and Markdown SBOM exports include all locked components and purls")
    func exportsCycloneDXAndMarkdownSBOM() throws {
        let report = DependencyLockAuditor.auditRepository(atRepoRoot: repoRoot)
        let cycloneJSON = report.exportCycloneDXJSON()
        let jsonObject = try #require(
            try JSONSerialization.jsonObject(with: Data(cycloneJSON.utf8)) as? [String: Any]
        )
        #expect(jsonObject["bomFormat"] as? String == "CycloneDX")
        #expect(jsonObject["specVersion"] as? String == "1.5")
        let components = try #require(jsonObject["components"] as? [[String: Any]])
        #expect(components.count == report.pins.count)
        #expect(components.contains { ($0["purl"] as? String) == "pkg:swift/containerization@0.38.0" })

        let markdown = report.exportSBOMMarkdown()
        #expect(markdown.contains("### 📦 ApexAgent Software Bill of Materials"))
        #expect(markdown.contains("`containerization`"))
        #expect(markdown.contains("`0.38.0`"))
        #expect(markdown.contains("`swift-log`"))
    }
}
