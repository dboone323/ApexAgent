import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Mesh Security Auditor Tests")
struct MeshSecurityAuditorTests {
    @Test("Audits compliant mesh configuration with full score and rate limiting")
    func compliantMeshAudit() {
        let config = MeshAuthConfig(
            lanModeEnabled: true,
            token: "9f8a3c4b5e2d1f0a9b8c7d6e5f4a3b2c",
            requireP2PApproval: true,
            tlsEnabled: true,
            bindAddress: "0.0.0.0"
        )

        let report = MeshSecurityAuditor.audit(config: config, burstCount: 50)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)
        #expect(report.rateLimitResult.limiterHealthy)
        #expect(report.rateLimitResult.burstAllowed == 20)
        #expect(report.rateLimitResult.burstThrottled == 30)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("Throttling Verified"))
    }

    @Test("Detects empty token in LAN mode as critical violation")
    func emptyLANTokenAudit() {
        let config = MeshAuthConfig(
            lanModeEnabled: true,
            token: "   ",
            requireP2PApproval: true,
            bindAddress: "0.0.0.0"
        )

        let report = MeshSecurityAuditor.audit(config: config)
        #expect(!report.passed)
        let hasEmptyTokenViolation = report.violations.contains { $0.ruleId == "mesh_insecure_lan_empty_token" }
        #expect(hasEmptyTokenViolation)
    }

    @Test("Detects low entropy and short token")
    func lowEntropyTokenAudit() {
        let config = MeshAuthConfig(
            lanModeEnabled: true,
            token: "aaaa1111", // Short and low entropy
            requireP2PApproval: true,
            bindAddress: "0.0.0.0"
        )

        let report = MeshSecurityAuditor.audit(config: config)
        #expect(!report.passed)
        let hasLengthViolation = report.violations.contains { $0.ruleId == "mesh_token_insufficient_length" }
        #expect(hasLengthViolation)
        let hasEntropyViolation = report.violations.contains { $0.ruleId == "mesh_token_low_entropy" }
        #expect(hasEntropyViolation)
    }

    @Test("Detects 0.0.0.0 bind when LAN mode is disabled")
    func unintendedWildcardBindAudit() {
        let config = MeshAuthConfig(
            lanModeEnabled: false,
            token: "9f8a3c4b5e2d1f0a9b8c7d6e5f4a3b2c",
            requireP2PApproval: true,
            bindAddress: "0.0.0.0"
        )

        let report = MeshSecurityAuditor.audit(config: config)
        #expect(!report.passed)
        let hasWildcardViolation = report.violations.contains { $0.ruleId == "mesh_unintended_wildcard_bind" }
        #expect(hasWildcardViolation)
    }

    @Test("Detects unrestricted P2P approval requirement")
    func disabledP2PApprovalAudit() {
        let config = MeshAuthConfig(
            lanModeEnabled: false,
            token: "9f8a3c4b5e2d1f0a9b8c7d6e5f4a3b2c",
            requireP2PApproval: false,
            bindAddress: "127.0.0.1"
        )

        let report = MeshSecurityAuditor.audit(config: config)
        #expect(!report.passed)
        let hasP2PViolation = report.violations.contains { $0.ruleId == "mesh_p2p_grant_unrestricted" }
        #expect(hasP2PViolation)
    }

    @Test("Calculates Shannon entropy accurately")
    func shannonEntropyCalculation() {
        let low = MeshSecurityAuditor.computeShannonEntropy(string: "aaaaaaaa")
        #expect(low == 0.0)

        let high = MeshSecurityAuditor.computeShannonEntropy(string: "0123456789abcdef")
        #expect(high >= 3.8)
    }
}
