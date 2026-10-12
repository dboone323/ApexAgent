//
//  ExternalSecretVaultAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 110: External Secret Vault & 1Password Reference Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 110 — External Secret Vault & 1Password Reference Auditor Tests")
struct ExternalSecretVaultAuditorTests {

    @Test("1Password, Keychain, Environment, and Vault URIs parse with correct structure")
    func testURIStructureParsing() {
        let opRef = ExternalSecretVaultAuditor.parseReference("op://Engineering/OpenAI/credential")
        #expect(opRef?.type == .onePassword)
        #expect(opRef?.vaultOrService == "Engineering")
        #expect(opRef?.itemOrPath == "OpenAI")
        #expect(opRef?.fieldOrAccount == "credential")

        let kcRef = ExternalSecretVaultAuditor.parseReference("keychain://geminiAPIKey")
        #expect(kcRef?.type == .keychain)
        #expect(kcRef?.vaultOrService == "geminiAPIKey")

        let envRef = ExternalSecretVaultAuditor.parseReference("env://HOME")
        #expect(envRef?.type == .environment)
        #expect(envRef?.itemOrPath == "HOME")

        let vaultRef = ExternalSecretVaultAuditor.parseReference("vault://secret/data/production/token")
        #expect(vaultRef?.type == .hashicorpVault)
        #expect(vaultRef?.vaultOrService == "secret")
        #expect(vaultRef?.itemOrPath == "data")
        #expect(vaultRef?.fieldOrAccount == "production")
    }

    @Test("Environment and 1Password reference resolution returns resolved descriptor")
    func testSecretResolution() {
        let envRef = ParsedSecretReference(
            rawURI: "env://PATH",
            type: .environment,
            vaultOrService: "environment",
            itemOrPath: "PATH"
        )
        let resolvedEnv = ExternalSecretVaultAuditor.resolveSecret(reference: envRef)
        #expect(resolvedEnv != nil)
        #expect(resolvedEnv?.contains("/") == true)

        let opRef = ParsedSecretReference(
            rawURI: "op://Vault/Item/field",
            type: .onePassword,
            vaultOrService: "Vault",
            itemOrPath: "Item",
            fieldOrAccount: "field"
        )
        let resolvedOp = ExternalSecretVaultAuditor.resolveSecret(reference: opRef)
        #expect(resolvedOp == "[RESOLVED_VIA_OP]")
    }

    @Test("Scanning clean configuration text with vault references passes audit")
    func testCleanVaultReferencesPassAudit() {
        let text = """
        service:
          openai_key: op://Development/OpenAI/api_key
          slack_token: keychain://slackBotToken
          env_target: env://DEPLOY_ENV
        """

        let report = ExternalSecretVaultAuditor.auditTextForVaultReferences(text)

        #expect(report.isCompliant)
        #expect(report.totalReferencesCount == 3)
        #expect(report.violations.isEmpty)
        #expect(report.securityScore >= 0.95)
    }

    @Test("Scanning text with hardcoded token prefixes trips fatal security violation")
    func testHardcodedTokenTripsFatal() {
        let text = """
        service:
          key: sk-proj-supersecretproductionkey1234567890
        """

        let report = ExternalSecretVaultAuditor.auditTextForVaultReferences(text)

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "HARDCODED_SECRET_DETECTED" && $0.isFatal }))
        #expect(report.securityScore < 0.6)
    }

    @Test("Malformed 1Password URI trips fatal violation")
    func testMalformed1PasswordURITripsFatal() {
        let text = "token: op://onlyonepart"
        let report = ExternalSecretVaultAuditor.auditTextForVaultReferences(text)

        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "MALFORMED_1PASSWORD_URI" && $0.isFatal }))
    }

    @Test("formatVaultReportMarkdown produces structured markdown table")
    func testMarkdownFormatting() {
        let ref = ParsedSecretReference(rawURI: "op://V/I/f", type: .onePassword, vaultOrService: "V", itemOrPath: "I")
        let report = VaultAuditReport(
            totalReferencesCount: 1,
            resolvedReferencesCount: 1,
            isCompliant: true,
            securityScore: 1.0,
            violations: [],
            parsedReferences: [ref]
        )

        let md = ExternalSecretVaultAuditor.formatVaultReportMarkdown(report)
        #expect(md.contains("### 🔐 External Secret Vault & Reference Security Audit"))
        #expect(md.contains("100%"))
        #expect(md.contains("op://V/I/f"))
    }
}
