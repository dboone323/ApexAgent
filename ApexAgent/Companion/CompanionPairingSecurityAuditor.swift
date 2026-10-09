import Foundation
import CryptoKit

// MARK: - Companion TLS Pairing & Ephemeral PIN Gate (Batch 96)

/// Transport Layer Security version supported for companion pairing.
public enum CompanionTLSVersion: String, Sendable, Codable, Comparable {
    case tls10 = "TLSv1.0"
    case tls11 = "TLSv1.1"
    case tls12 = "TLSv1.2"
    case tls13 = "TLSv1.3"

    private var numericRank: Int {
        switch self {
        case .tls10: return 10
        case .tls11: return 11
        case .tls12: return 12
        case .tls13: return 13
        }
    }

    public static func < (lhs: CompanionTLSVersion, rhs: CompanionTLSVersion) -> Bool {
        lhs.numericRank < rhs.numericRank
    }
}

/// TLS connection parameters evaluated during companion pairing handshake.
public struct CompanionTLSConfig: Sendable, Codable, Equatable {
    public var version: CompanionTLSVersion
    public var cipherSuite: String
    public var peerCertificateFingerprint: String?
    public var pinnedCertificateFingerprint: String?
    public var isMutualTLSEnforced: Bool

    public init(
        version: CompanionTLSVersion = .tls13,
        cipherSuite: String = "TLS_AES_256_GCM_SHA384",
        peerCertificateFingerprint: String? = nil,
        pinnedCertificateFingerprint: String? = nil,
        isMutualTLSEnforced: Bool = true
    ) {
        self.version = version
        self.cipherSuite = cipherSuite
        self.peerCertificateFingerprint = peerCertificateFingerprint
        self.pinnedCertificateFingerprint = pinnedCertificateFingerprint
        self.isMutualTLSEnforced = isMutualTLSEnforced
    }
}

/// Ephemeral 6-digit PIN state for secure out-of-band visual/numeric pairing verification.
public struct EphemeralPairingPIN: Sendable, Codable, Equatable {
    public let pinCode: String
    public let createdAt: Date
    public let ttlSeconds: TimeInterval
    public var failedAttempts: Int
    public let maxAttempts: Int

    public init(
        pinCode: String,
        createdAt: Date = Date(),
        ttlSeconds: TimeInterval = 60.0,
        failedAttempts: Int = 0,
        maxAttempts: Int = 3
    ) {
        self.pinCode = pinCode
        self.createdAt = createdAt
        self.ttlSeconds = ttlSeconds
        self.failedAttempts = failedAttempts
        self.maxAttempts = maxAttempts
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        date.timeIntervalSince(createdAt) > ttlSeconds
    }

    public var isLockedOut: Bool {
        failedAttempts >= maxAttempts
    }
}

/// Cryptographic handshake payload exchanging mutual challenges and proof-of-possession HMAC.
public struct CompanionPairingHandshake: Sendable, Codable, Equatable {
    public let deviceId: String
    public let deviceName: String
    public let clientNonce: String
    public let serverNonce: String
    public let timestamp: Date
    public let clientProofHMAC: String

    public init(
        deviceId: String,
        deviceName: String,
        clientNonce: String,
        serverNonce: String,
        timestamp: Date = Date(),
        clientProofHMAC: String
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.timestamp = timestamp
        self.clientProofHMAC = clientProofHMAC
    }
}

/// Violation detected during companion pairing audit.
public struct CompanionPairingViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Result of evaluating companion device pairing request.
public struct CompanionPairingSecurityReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [CompanionPairingViolation]
    public let sessionToken: String?
    public let authorizedDeviceId: String?

    public init(
        passed: Bool,
        score: Double,
        violations: [CompanionPairingViolation],
        sessionToken: String?,
        authorizedDeviceId: String?
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.sessionToken = sessionToken
        self.authorizedDeviceId = authorizedDeviceId
    }
}

/// Security auditor for Companion TLS channel security and Ephemeral PIN challenge verification.
public enum CompanionPairingSecurityAuditor {

    private static let prohibitedCiphers = [
        "RC4", "3DES", "DES", "NULL", "EXPORT", "anon", "CBC"
    ]

    // MARK: - Ephemeral PIN Generation & Constant-Time Verification

    /// Generates a cryptographically secure 6-digit numeric PIN with designated TTL.
    public static func generateEphemeralPIN(ttlSeconds: TimeInterval = 60.0) -> EphemeralPairingPIN {
        var randomBytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        let rawInt = randomBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        let pinNumber = rawInt % 1_000_000
        let pinCode = String(format: "%06d", pinNumber)

        return EphemeralPairingPIN(pinCode: pinCode, createdAt: Date(), ttlSeconds: ttlSeconds)
    }

    /// Verifies an attempted PIN using constant-time comparison and tracks failed attempts.
    public static func verifyPIN(
        _ attemptedPin: String,
        state: inout EphemeralPairingPIN,
        at date: Date = Date()
    ) -> Bool {
        if state.isLockedOut || state.isExpired(at: date) {
            return false
        }

        // Constant-time comparison using SHA256 hashes to prevent timing side channels
        let expectedHash = SHA256.hash(data: Data(state.pinCode.utf8))
        let attemptHash = SHA256.hash(data: Data(attemptedPin.utf8))
        let isMatch = (expectedHash == attemptHash)

        if isMatch {
            return true
        } else {
            state.failedAttempts += 1
            return false
        }
    }

    // MARK: - TLS Transport Audit

    /// Audits TLS transport configuration for version adherence, secure ciphers, and certificate pinning.
    public static func auditTLSConnection(config: CompanionTLSConfig) -> [CompanionPairingViolation] {
        var violations: [CompanionPairingViolation] = []

        // 1. Minimum TLS Version check (TLS 1.2 minimum required, TLS 1.3 recommended)
        if config.version < .tls12 {
            violations.append(CompanionPairingViolation(
                code: "INSECURE_TLS_VERSION",
                message: "TLS version \(config.version.rawValue) is obsolete and vulnerable. TLSv1.2 or TLSv1.3 is required."
            ))
        } else if config.version == .tls12 {
            violations.append(CompanionPairingViolation(
                code: "DEPRECATED_TLS_1_2",
                message: "TLSv1.2 is allowed but TLSv1.3 is strongly recommended for local companion pairing.",
                isFatal: false
            ))
        }

        // 2. Cipher suite evaluation
        for badCipher in prohibitedCiphers {
            if config.cipherSuite.localizedCaseInsensitiveContains(badCipher) {
                violations.append(CompanionPairingViolation(
                    code: "WEAK_CIPHER_SUITE",
                    message: "Cipher suite \(config.cipherSuite) contains weak algorithm '\(badCipher)'."
                ))
                break
            }
        }

        // 3. Mutual TLS requirement
        if !config.isMutualTLSEnforced {
            violations.append(CompanionPairingViolation(
                code: "MUTUAL_TLS_DISABLED",
                message: "Mutual TLS authentication must be enforced for companion pairing."
            ))
        }

        // 4. Certificate Pinning check
        if let pinned = config.pinnedCertificateFingerprint, !pinned.isEmpty {
            if let peer = config.peerCertificateFingerprint {
                let normalizedPinned = pinned.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalizedPeer = peer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if normalizedPinned != normalizedPeer {
                    violations.append(CompanionPairingViolation(
                        code: "CERTIFICATE_PIN_MISMATCH",
                        message: "Peer certificate fingerprint does not match pinned trust root."
                    ))
                }
            } else {
                violations.append(CompanionPairingViolation(
                    code: "MISSING_PEER_CERTIFICATE",
                    message: "Pinned certificate configured but peer presented no certificate fingerprint."
                ))
            }
        }

        return violations
    }

    // MARK: - Handshake Proof HMAC Calculation & Verification

    /// Computes HMAC-SHA256 client proof over deviceId, nonces, and timestamp using PIN secret.
    public static func computeHandshakeHMAC(
        secretPIN: String,
        deviceId: String,
        clientNonce: String,
        serverNonce: String,
        timestamp: Date
    ) -> String {
        let message = "\(deviceId):\(clientNonce):\(serverNonce):\(Int64(timestamp.timeIntervalSince1970))"
        let key = SymmetricKey(data: Data(secretPIN.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return Data(mac).map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Comprehensive Handshake Audit

    /// Audits the entire companion pairing exchange including TLS layer, replay protection, and HMAC proof.
    public static func auditPairingHandshake(
        handshake: CompanionPairingHandshake,
        secretPIN: String,
        tlsConfig: CompanionTLSConfig,
        at date: Date = Date(),
        maxClockSkewSeconds: TimeInterval = 30.0
    ) -> CompanionPairingSecurityReport {
        var violations = auditTLSConnection(config: tlsConfig)

        // 1. Device identity validation
        let cleanId = handshake.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanId.isEmpty {
            violations.append(CompanionPairingViolation(
                code: "EMPTY_DEVICE_ID",
                message: "Companion device ID cannot be empty."
            ))
        }

        // 2. Clock skew / Replay window check
        let skew = abs(date.timeIntervalSince(handshake.timestamp))
        if skew > maxClockSkewSeconds {
            violations.append(CompanionPairingViolation(
                code: "EXCESSIVE_CLOCK_SKEW",
                message: "Handshake timestamp skew (\(Int(skew))s) exceeds allowable replay window (\(Int(maxClockSkewSeconds))s)."
            ))
        }

        // 3. Nonce entropy check
        if handshake.clientNonce.count < 16 || handshake.serverNonce.count < 16 {
            violations.append(CompanionPairingViolation(
                code: "INSUFFICIENT_NONCE_ENTROPY",
                message: "Handshake nonces must be at least 16 characters in length."
            ))
        }

        // 4. HMAC proof verification
        let expectedHMAC = computeHandshakeHMAC(
            secretPIN: secretPIN,
            deviceId: handshake.deviceId,
            clientNonce: handshake.clientNonce,
            serverNonce: handshake.serverNonce,
            timestamp: handshake.timestamp
        )

        let isProofValid = (expectedHMAC.lowercased() == handshake.clientProofHMAC.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if !isProofValid {
            violations.append(CompanionPairingViolation(
                code: "INVALID_HANDSHAKE_PROOF",
                message: "Client HMAC proof-of-possession failed verification."
            ))
        }

        let fatalViolations = violations.filter(\.isFatal)
        let nonFatalViolations = violations.filter { !$0.isFatal }
        let passed = fatalViolations.isEmpty

        var score = 100.0 - Double(fatalViolations.count) * 25.0 - Double(nonFatalViolations.count) * 10.0
        score = max(0.0, min(100.0, score))

        let sessionToken = passed ? UUID().uuidString : nil
        let authorizedId = passed ? handshake.deviceId : nil

        return CompanionPairingSecurityReport(
            passed: passed,
            score: score,
            violations: violations,
            sessionToken: sessionToken,
            authorizedDeviceId: authorizedId
        )
    }
}
