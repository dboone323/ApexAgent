import Foundation
import Testing
import Security
@testable import ApexAgentCore

@Suite("Batch 72 — Keychain Manager Attribute & Secure Memory Zeroing Gate Tests")
struct KeychainIntegrityAuditorTests {

    @Test("Compliant query attributes pass audit with 100% score")
    func compliantAttributesPass() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.apexagent.ApexAgent",
            kSecAttrAccount as String: "openai_api_key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false
        ]

        let report = KeychainIntegrityAuditor.auditAttributes(query)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.isDeviceBound)
        #expect(report.accessibilityValid)
        #expect(report.dataProtectionEnabled)
        #expect(report.violations.isEmpty)
    }

    @Test("Cloud synchronizable or weak accessibility attributes trigger fatal violations")
    func nonCompliantAttributesFail() {
        let weakQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "leaked_token",
            kSecAttrAccessible as String: "kSecAttrAccessibleAlways",
            kSecAttrSynchronizable as String: true
        ]

        let report = KeychainIntegrityAuditor.auditAttributes(weakQuery)
        #expect(!report.passed)
        #expect(!report.isDeviceBound)
        #expect(!report.accessibilityValid)
        #expect(report.violations.contains { $0.code == "WEAK_ACCESSIBILITY_ATTRIBUTE" })
        #expect(report.violations.contains { $0.code == "CLOUD_SYNC_ENABLED" })
    }

    @Test("Shannon entropy evaluation properly scores high-entropy vs trivial secrets")
    func entropyEvaluationAccuratelyDistinguishesSecrets() {
        let highEntropySecret = "xK9#mQ2$pL8@vW5!zR1^jT7&yU4*"
        let evalHigh = KeychainIntegrityAuditor.evaluateEntropy(secret: highEntropySecret)
        #expect(evalHigh.isAdequate)
        #expect(evalHigh.entropyPerCharacter > 4.0)
        #expect(evalHigh.characterSetDiversityScore == 4)

        let repetitiveSecret = "aaaaaaaaaaaaaaaa"
        let evalLow = KeychainIntegrityAuditor.evaluateEntropy(secret: repetitiveSecret)
        #expect(!evalLow.isAdequate)
        #expect(evalLow.entropyPerCharacter == 0.0)
        #expect(evalLow.characterSetDiversityScore == 1)
    }

    @Test("SecureBytesBuffer stores data, allows safe access, and zeroes memory on wipe")
    func secureBytesBufferWipesMemory() {
        let secret = "SuperSecretPassword123!"
        let buffer = SecureBytesBuffer(string: secret)
        #expect(buffer.count == secret.utf8.count)
        #expect(!buffer.isZeroed)

        var extracted = ""
        buffer.withUnsafeBytes { rawPtr in
            if let ptr = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                extracted = String(bytes: UnsafeBufferPointer(start: ptr, count: rawPtr.count), encoding: .utf8) ?? ""
            }
        }
        #expect(extracted == secret)

        buffer.wipe()
        #expect(buffer.isZeroed)
    }

    @Test("secureZeroMemory wipes raw Data buffer completely")
    func secureZeroMemoryWipesData() {
        var data = Data([0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE])
        #expect(data.contains { $0 != 0 })

        KeychainIntegrityAuditor.secureZeroMemory(&data)
        #expect(data.allSatisfy { $0 == 0 })
    }
}
