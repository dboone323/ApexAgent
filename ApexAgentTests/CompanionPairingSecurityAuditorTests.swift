import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 96 — Companion TLS Pairing & Ephemeral PIN Gate Tests")
struct CompanionPairingSecurityAuditorTests {

    @Test("Ephemeral PIN generates valid 6-digit code with proper TTL and lockout state")
    func ephemeralPinGeneration() {
        let pin = CompanionPairingSecurityAuditor.generateEphemeralPIN(ttlSeconds: 60.0)

        #expect(pin.pinCode.count == 6)
        #expect(Int(pin.pinCode) != nil)
        #expect(!pin.isExpired())
        #expect(!pin.isLockedOut)
        #expect(pin.failedAttempts == 0)
    }

    @Test("PIN verification succeeds on match and fails on incorrect input")
    func pinVerificationMatchingAndMismatch() {
        var state = EphemeralPairingPIN(pinCode: "123456", ttlSeconds: 60.0, failedAttempts: 0, maxAttempts: 3)

        // Incorrect guess
        let failed = CompanionPairingSecurityAuditor.verifyPIN("000000", state: &state)
        #expect(!failed)
        #expect(state.failedAttempts == 1)
        #expect(!state.isLockedOut)

        // Correct guess
        let success = CompanionPairingSecurityAuditor.verifyPIN("123456", state: &state)
        #expect(success)
        #expect(state.failedAttempts == 1)
    }

    @Test("PIN verification enforces lockout after maximum failed attempts")
    func pinVerificationLockout() {
        var state = EphemeralPairingPIN(pinCode: "888999", ttlSeconds: 60.0, failedAttempts: 0, maxAttempts: 2)

        _ = CompanionPairingSecurityAuditor.verifyPIN("111111", state: &state)
        #expect(state.failedAttempts == 1)

        _ = CompanionPairingSecurityAuditor.verifyPIN("222222", state: &state)
        #expect(state.failedAttempts == 2)
        #expect(state.isLockedOut)

        // Even with the correct PIN, lockout rejects verification
        let blocked = CompanionPairingSecurityAuditor.verifyPIN("888999", state: &state)
        #expect(!blocked)
    }

    @Test("PIN verification rejects expired PIN")
    func pinVerificationExpired() {
        let pastDate = Date().addingTimeInterval(-100.0)
        var state = EphemeralPairingPIN(pinCode: "555111", createdAt: pastDate, ttlSeconds: 30.0)

        #expect(state.isExpired())
        let result = CompanionPairingSecurityAuditor.verifyPIN("555111", state: &state)
        #expect(!result)
    }

    @Test("TLS connection audit rejects obsolete TLS 1.0 and weak RC4 cipher")
    func tlsAuditRejectsInsecureParams() {
        let badConfig = CompanionTLSConfig(
            version: .tls10,
            cipherSuite: "TLS_RSA_WITH_RC4_128_SHA",
            isMutualTLSEnforced: false
        )

        let violations = CompanionPairingSecurityAuditor.auditTLSConnection(config: badConfig)
        #expect(violations.contains { $0.code == "INSECURE_TLS_VERSION" })
        #expect(violations.contains { $0.code == "WEAK_CIPHER_SUITE" })
        #expect(violations.contains { $0.code == "MUTUAL_TLS_DISABLED" })
    }

    @Test("Certificate pinning detects mismatch between peer fingerprint and pinned root")
    func certPinningDetectsMismatch() {
        let config = CompanionTLSConfig(
            version: .tls13,
            cipherSuite: "TLS_AES_256_GCM_SHA384",
            peerCertificateFingerprint: "aa:bb:cc:dd",
            pinnedCertificateFingerprint: "11:22:33:44",
            isMutualTLSEnforced: true
        )

        let violations = CompanionPairingSecurityAuditor.auditTLSConnection(config: config)
        #expect(violations.contains { $0.code == "CERTIFICATE_PIN_MISMATCH" })
    }

    @Test("Valid companion pairing handshake passes security audit with session token")
    func validPairingHandshakePasses() {
        let pin = "654321"
        let deviceId = "ipad-companion-pro-01"
        let clientNonce = "nonce_client_12345678"
        let serverNonce = "nonce_server_87654321"
        let now = Date()

        let hmac = CompanionPairingSecurityAuditor.computeHandshakeHMAC(
            secretPIN: pin,
            deviceId: deviceId,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timestamp: now
        )

        let handshake = CompanionPairingHandshake(
            deviceId: deviceId,
            deviceName: "User's iPad Pro",
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timestamp: now,
            clientProofHMAC: hmac
        )

        let tlsConfig = CompanionTLSConfig(
            version: .tls13,
            cipherSuite: "TLS_AES_256_GCM_SHA384",
            isMutualTLSEnforced: true
        )

        let report = CompanionPairingSecurityAuditor.auditPairingHandshake(
            handshake: handshake,
            secretPIN: pin,
            tlsConfig: tlsConfig,
            at: now
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.authorizedDeviceId == deviceId)
        #expect(report.sessionToken != nil)
        #expect(report.violations.isEmpty)
    }

    @Test("Replay attempt with excessive clock skew is rejected")
    func replayAttemptExcessiveSkewFails() {
        let pin = "654321"
        let deviceId = "iphone-16-pro"
        let clientNonce = "nonce_client_12345678"
        let serverNonce = "nonce_server_87654321"
        let staleDate = Date().addingTimeInterval(-120.0) // 2 minutes in past

        let hmac = CompanionPairingSecurityAuditor.computeHandshakeHMAC(
            secretPIN: pin,
            deviceId: deviceId,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timestamp: staleDate
        )

        let handshake = CompanionPairingHandshake(
            deviceId: deviceId,
            deviceName: "User's iPhone",
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timestamp: staleDate,
            clientProofHMAC: hmac
        )

        let tlsConfig = CompanionTLSConfig(version: .tls13, isMutualTLSEnforced: true)

        let report = CompanionPairingSecurityAuditor.auditPairingHandshake(
            handshake: handshake,
            secretPIN: pin,
            tlsConfig: tlsConfig,
            at: Date(),
            maxClockSkewSeconds: 30.0
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "EXCESSIVE_CLOCK_SKEW" })
        #expect(report.sessionToken == nil)
    }

    @Test("Invalid HMAC client proof is rejected")
    func invalidHMACProofFails() {
        let pin = "654321"
        let deviceId = "iphone-16-pro"
        let clientNonce = "nonce_client_12345678"
        let serverNonce = "nonce_server_87654321"
        let now = Date()

        let handshake = CompanionPairingHandshake(
            deviceId: deviceId,
            deviceName: "User's iPhone",
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            timestamp: now,
            clientProofHMAC: "invalid_tampered_hmac_proof"
        )

        let tlsConfig = CompanionTLSConfig(version: .tls13, isMutualTLSEnforced: true)

        let report = CompanionPairingSecurityAuditor.auditPairingHandshake(
            handshake: handshake,
            secretPIN: pin,
            tlsConfig: tlsConfig,
            at: now
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "INVALID_HANDSHAKE_PROOF" })
    }
}
