import Foundation
import Security

// MARK: - Keychain Integrity & Secure Memory Zeroing Gate (Batch 72)

/// Configuration policy for Keychain attribute auditing.
public struct KeychainAuditPolicy: Sendable, Codable, Equatable {
    /// Expected accessibility constant (default: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly).
    public var requiredAccessibility: String
    /// Disallow cloud/iCloud keychain synchronization.
    public var disallowCloudSync: Bool
    /// Minimum Shannon entropy bits per character for high-value secrets (e.g., API keys).
    public var minEntropyBits: Double
    /// Minimum raw byte length for credentials.
    public var minSecretLength: Int

    public init(
        requiredAccessibility: String = (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String),
        disallowCloudSync: Bool = true,
        minEntropyBits: Double = 3.0,
        minSecretLength: Int = 16
    ) {
        self.requiredAccessibility = requiredAccessibility
        self.disallowCloudSync = disallowCloudSync
        self.minEntropyBits = minEntropyBits
        self.minSecretLength = minSecretLength
    }
}

/// Keychain security violation description.
public struct KeychainViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Report produced by auditing Keychain query or item attributes.
public struct KeychainAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let violations: [KeychainViolation]
    public let isDeviceBound: Bool
    public let accessibilityValid: Bool
    public let dataProtectionEnabled: Bool

    public init(
        passed: Bool,
        score: Double,
        violations: [KeychainViolation],
        isDeviceBound: Bool,
        accessibilityValid: Bool,
        dataProtectionEnabled: Bool
    ) {
        self.passed = passed
        self.score = score
        self.violations = violations
        self.isDeviceBound = isDeviceBound
        self.accessibilityValid = accessibilityValid
        self.dataProtectionEnabled = dataProtectionEnabled
    }
}

/// Result of evaluating the cryptographic entropy of a stored secret.
public struct SecretEntropyEvaluation: Sendable, Codable, Equatable {
    public let length: Int
    public let entropyPerCharacter: Double
    public let isAdequate: Bool
    public let characterSetDiversityScore: Int

    public init(
        length: Int,
        entropyPerCharacter: Double,
        isAdequate: Bool,
        characterSetDiversityScore: Int
    ) {
        self.length = length
        self.entropyPerCharacter = entropyPerCharacter
        self.isAdequate = isAdequate
        self.characterSetDiversityScore = characterSetDiversityScore
    }
}

/// Zero-wipeable in-memory buffer for handling sensitive credentials securely.
public final class SecureBytesBuffer: @unchecked Sendable {
    private var buffer: [UInt8]
    private var isWiped: Bool = false
    private let lock = NSLock()

    public init(data: Data) {
        self.buffer = Array(data)
    }

    public init(string: String) {
        self.buffer = Array((string.data(using: .utf8) ?? Data()))
    }

    deinit {
        wipe()
    }

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    public var isZeroed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isWiped || buffer.allSatisfy { $0 == 0 }
    }

    /// Access the underlying raw bytes safely within a closure.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try buffer.withUnsafeBytes(body)
    }

    /// Explicitly overwrites the memory buffer with zeroes.
    public func wipe() {
        lock.lock()
        defer { lock.unlock() }
        guard !isWiped else { return }
        for i in 0..<buffer.count {
            buffer[i] = 0
        }
        isWiped = true
    }
}

/// Security auditor for macOS Keychain attributes and memory wiping.
public enum KeychainIntegrityAuditor {

    // MARK: - Query & Attribute Audit

    /// Audits a Keychain dictionary for strict device-bound attributes and modern data protection.
    public static func auditAttributes(
        _ attributes: [String: Any],
        policy: KeychainAuditPolicy = KeychainAuditPolicy()
    ) -> KeychainAuditReport {
        var violations: [KeychainViolation] = []
        var isDeviceBound = true
        var accessibilityValid = false
        var dataProtectionEnabled = false

        // 1. Accessibility Check
        let accessibleKey = kSecAttrAccessible as String
        if let accessibleValue = attributes[accessibleKey] as? String {
            if accessibleValue == policy.requiredAccessibility {
                accessibilityValid = true
            } else {
                violations.append(KeychainViolation(
                    code: "WEAK_ACCESSIBILITY_ATTRIBUTE",
                    message: "Item uses '\(accessibleValue)' instead of required '\(policy.requiredAccessibility)'.",
                    isFatal: true
                ))
            }
        } else {
            violations.append(KeychainViolation(
                code: "MISSING_ACCESSIBILITY_ATTRIBUTE",
                message: "Keychain query does not declare an explicit kSecAttrAccessible attribute.",
                isFatal: true
            ))
        }

        // 2. Cloud Sync Check
        let syncKey = kSecAttrSynchronizable as String
        if let syncValue = attributes[syncKey] as? Bool, syncValue {
            isDeviceBound = false
            violations.append(KeychainViolation(
                code: "CLOUD_SYNC_ENABLED",
                message: "kSecAttrSynchronizable is set to true, permitting cloud synchronization of credentials.",
                isFatal: true
            ))
        }

        // 3. Data Protection Keychain
        let dpKey = kSecUseDataProtectionKeychain as String
        if let dpValue = attributes[dpKey] as? Bool, dpValue {
            dataProtectionEnabled = true
        }

        let passed = violations.isEmpty
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 40.0)

        return KeychainAuditReport(
            passed: passed,
            score: score,
            violations: violations,
            isDeviceBound: isDeviceBound,
            accessibilityValid: accessibilityValid,
            dataProtectionEnabled: dataProtectionEnabled
        )
    }

    // MARK: - Secret Entropy Evaluation

    /// Computes Shannon entropy (bits per char) and character set diversity for a secret string.
    public static func evaluateEntropy(
        secret: String,
        policy: KeychainAuditPolicy = KeychainAuditPolicy()
    ) -> SecretEntropyEvaluation {
        let length = secret.count
        guard length > 0 else {
            return SecretEntropyEvaluation(
                length: 0,
                entropyPerCharacter: 0.0,
                isAdequate: false,
                characterSetDiversityScore: 0
            )
        }

        // Frequency distribution
        var frequencies: [Character: Int] = [:]
        for char in secret {
            frequencies[char, default: 0] += 1
        }

        var entropy: Double = 0.0
        let total = Double(length)
        for count in frequencies.values {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }

        // Diversity: lowercase, uppercase, digits, symbols
        var diversity = 0
        if secret.contains(where: { $0.isLowercase }) { diversity += 1 }
        if secret.contains(where: { $0.isUppercase }) { diversity += 1 }
        if secret.contains(where: { $0.isNumber }) { diversity += 1 }
        if secret.contains(where: { $0.isPunctuation || $0.isSymbol }) { diversity += 1 }

        let adequate = length >= policy.minSecretLength
            && entropy >= policy.minEntropyBits
            && diversity >= 2

        return SecretEntropyEvaluation(
            length: length,
            entropyPerCharacter: entropy,
            isAdequate: adequate,
            characterSetDiversityScore: diversity
        )
    }

    // MARK: - Memory Zeroing

    /// Securely wipes a Data buffer by zeroing each byte.
    public static func secureZeroMemory(_ data: inout Data) {
        data.withUnsafeMutableBytes { (rawPtr: UnsafeMutableRawBufferPointer) in
            guard let baseAddress = rawPtr.baseAddress else { return }
            memset(baseAddress, 0, rawPtr.count)
        }
    }
}
