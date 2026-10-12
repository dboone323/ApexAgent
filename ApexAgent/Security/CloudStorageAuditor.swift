//
//  CloudStorageAuditor.swift
//  ApexAgent
//
//  Created for Batch 108: Cloud Storage Artifact Export & Presigned URL Security Auditor.
//

import Foundation
import CryptoKit

// MARK: - Cloud Storage Providers

public enum CloudStorageProvider: String, Sendable, Codable, CaseIterable {
    case s3 = "Amazon S3"
    case r2 = "Cloudflare R2"
    case gcs = "Google Cloud Storage"
    case minio = "MinIO S3-Compatible"
}

// MARK: - Cloud Storage Configuration

public struct CloudStorageExportConfig: Sendable, Codable, Equatable {
    public var provider: CloudStorageProvider
    public var endpointURL: URL
    public var bucketName: String
    public var maxObjectSizeBytes: Int
    public var defaultExpirationSeconds: Int
    public var maxAllowedExpirationSeconds: Int
    public var requireServerSideEncryption: Bool

    public init(
        provider: CloudStorageProvider = .s3,
        endpointURL: URL = URL(string: "https://s3.us-east-1.amazonaws.com")!,
        bucketName: String = "apex-agent-artifacts",
        maxObjectSizeBytes: Int = 50_000_000,
        defaultExpirationSeconds: Int = 3600,
        maxAllowedExpirationSeconds: Int = 86400,
        requireServerSideEncryption: Bool = true
    ) {
        self.provider = provider
        self.endpointURL = endpointURL
        self.bucketName = bucketName
        self.maxObjectSizeBytes = maxObjectSizeBytes
        self.defaultExpirationSeconds = defaultExpirationSeconds
        self.maxAllowedExpirationSeconds = maxAllowedExpirationSeconds
        self.requireServerSideEncryption = requireServerSideEncryption
    }
}

// MARK: - Presigned URL Verification

public struct PresignedURLAuditResult: Sendable, Codable, Equatable {
    public let isValid: Bool
    public let isExpired: Bool
    public let expirationSeconds: Int
    public let algorithm: String?
    public let credentialScope: String?
    public let reason: String?

    public init(
        isValid: Bool,
        isExpired: Bool,
        expirationSeconds: Int,
        algorithm: String?,
        credentialScope: String?,
        reason: String?
    ) {
        self.isValid = isValid
        self.isExpired = isExpired
        self.expirationSeconds = expirationSeconds
        self.algorithm = algorithm
        self.credentialScope = credentialScope
        self.reason = reason
    }
}

public struct SignedURLVerifier: Sendable {
    private static let iso8601BasicDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    public static func verifySigV4URL(
        url: URL,
        maxAllowedExpirationSeconds: Int = 86400,
        currentDate: Date = Date()
    ) -> PresignedURLAuditResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: 0, algorithm: nil, credentialScope: nil, reason: "Missing query parameters in presigned URL")
        }

        let queryMap = Dictionary(queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        }, uniquingKeysWith: { first, _ in first })

        guard let algorithm = queryMap["X-Amz-Algorithm"] else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: 0, algorithm: nil, credentialScope: nil, reason: "Missing X-Amz-Algorithm")
        }

        guard algorithm == "AWS4-HMAC-SHA256" else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: 0, algorithm: algorithm, credentialScope: nil, reason: "Unsupported algorithm '\(algorithm)'; expected AWS4-HMAC-SHA256")
        }

        guard let dateStr = queryMap["X-Amz-Date"], let signedDate = iso8601BasicDateFormatter.date(from: dateStr) else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: 0, algorithm: algorithm, credentialScope: nil, reason: "Missing or invalid X-Amz-Date timestamp")
        }

        guard let expiresStr = queryMap["X-Amz-Expires"], let expiresSeconds = Int(expiresStr) else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: 0, algorithm: algorithm, credentialScope: nil, reason: "Missing or invalid X-Amz-Expires")
        }

        guard queryMap["X-Amz-Signature"] != nil else {
            return PresignedURLAuditResult(isValid: false, isExpired: false, expirationSeconds: expiresSeconds, algorithm: algorithm, credentialScope: nil, reason: "Missing X-Amz-Signature")
        }

        let credentialScope = queryMap["X-Amz-Credential"]

        if expiresSeconds > maxAllowedExpirationSeconds {
            return PresignedURLAuditResult(
                isValid: false,
                isExpired: false,
                expirationSeconds: expiresSeconds,
                algorithm: algorithm,
                credentialScope: credentialScope,
                reason: "X-Amz-Expires (\(expiresSeconds)s) exceeds security ceiling (\(maxAllowedExpirationSeconds)s)"
            )
        }

        let expirationDate = signedDate.addingTimeInterval(TimeInterval(expiresSeconds))
        let isExpired = currentDate > expirationDate

        if isExpired {
            return PresignedURLAuditResult(
                isValid: false,
                isExpired: true,
                expirationSeconds: expiresSeconds,
                algorithm: algorithm,
                credentialScope: credentialScope,
                reason: "Presigned URL has expired"
            )
        }

        return PresignedURLAuditResult(
            isValid: true,
            isExpired: false,
            expirationSeconds: expiresSeconds,
            algorithm: algorithm,
            credentialScope: credentialScope,
            reason: nil
        )
    }
}

// MARK: - Cloud Storage Security Violations & Auditor

public struct CloudStorageViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct CloudStorageAuditReport: Sendable, Codable, Equatable {
    public let provider: CloudStorageProvider
    public let bucketName: String
    public let endpointURL: String
    public let isCompliant: Bool
    public let securityScore: Double
    public let violations: [CloudStorageViolation]

    public init(
        provider: CloudStorageProvider,
        bucketName: String,
        endpointURL: String,
        isCompliant: Bool,
        securityScore: Double,
        violations: [CloudStorageViolation]
    ) {
        self.provider = provider
        self.bucketName = bucketName
        self.endpointURL = endpointURL
        self.isCompliant = isCompliant
        self.securityScore = securityScore
        self.violations = violations
    }
}

public struct CloudStorageAuditor: Sendable {

    /// Validates object keys to prevent directory traversal and illegal characters.
    public static func auditObjectKey(_ key: String) -> [CloudStorageViolation] {
        var violations: [CloudStorageViolation] = []

        if key.contains("..") || key.contains("%2e%2e") || key.contains("%2E%2E") {
            violations.append(CloudStorageViolation(
                code: "PATH_TRAVERSAL_IN_KEY",
                message: "Object key contains directory traversal sequence ('..'): '\(key)'.",
                isFatal: true
            ))
        }

        if key.hasPrefix("/") || key.hasPrefix("\\") {
            violations.append(CloudStorageViolation(
                code: "LEADING_SLASH_IN_KEY",
                message: "Object keys should not begin with a leading slash: '\(key)'.",
                isFatal: false
            ))
        }

        if key.utf8.count > 1024 {
            violations.append(CloudStorageViolation(
                code: "OBJECT_KEY_TOO_LONG",
                message: "Object key length (\(key.utf8.count) bytes) exceeds 1024-byte S3 limit.",
                isFatal: true
            ))
        }

        return violations
    }

    /// Validates bucket naming standards (DNS-compliant: 3-63 chars, lowercase, no consecutive dots).
    public static func auditBucketName(_ name: String) -> [CloudStorageViolation] {
        var violations: [CloudStorageViolation] = []

        if name.count < 3 || name.count > 63 {
            violations.append(CloudStorageViolation(
                code: "INVALID_BUCKET_LENGTH",
                message: "Bucket name must be between 3 and 63 characters long.",
                isFatal: true
            ))
        }

        if name.lowercased() != name {
            violations.append(CloudStorageViolation(
                code: "UPPERCASE_IN_BUCKET_NAME",
                message: "Bucket names must not contain uppercase characters.",
                isFatal: true
            ))
        }

        if name.contains("..") {
            violations.append(CloudStorageViolation(
                code: "CONSECUTIVE_DOTS_IN_BUCKET",
                message: "Bucket names must not contain consecutive dots.",
                isFatal: true
            ))
        }

        return violations
    }

    /// Evaluates full export configuration and presigned URL policy.
    public static func auditConfiguration(_ config: CloudStorageExportConfig) -> CloudStorageAuditReport {
        var violations: [CloudStorageViolation] = []

        // 1. Bucket name validation
        violations.append(contentsOf: auditBucketName(config.bucketName))

        // 2. Transport Security Check
        let isLocal = (config.endpointURL.host == "localhost" || config.endpointURL.host == "127.0.0.1")
        if config.endpointURL.scheme?.lowercased() != "https" {
            if isLocal && config.provider == .minio {
                violations.append(CloudStorageViolation(
                    code: "LOCAL_MINIO_HTTP_ALLOWED",
                    message: "Plaintext HTTP accepted for local MinIO testing instance.",
                    isFatal: false
                ))
            } else {
                violations.append(CloudStorageViolation(
                    code: "INSECURE_STORAGE_ENDPOINT",
                    message: "Cloud storage endpoint must use HTTPS to protect object data and tokens.",
                    isFatal: true
                ))
            }
        }

        // 3. Expiration threshold check
        if config.defaultExpirationSeconds > config.maxAllowedExpirationSeconds {
            violations.append(CloudStorageViolation(
                code: "EXCESSIVE_DEFAULT_EXPIRATION",
                message: "Default expiration (\(config.defaultExpirationSeconds)s) exceeds max allowed limit (\(config.maxAllowedExpirationSeconds)s).",
                isFatal: true
            ))
        }

        // 4. Server-Side Encryption
        if !config.requireServerSideEncryption {
            violations.append(CloudStorageViolation(
                code: "SERVER_SIDE_ENCRYPTION_DISABLED",
                message: "Server-side encryption is disabled for artifact exports; enabling AES-256 or KMS is strongly recommended.",
                isFatal: false
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.4) - (Double(warnCount) * 0.1)
        let score = max(0.0, min(1.0, rawScore))
        let compliant = fatalCount == 0

        return CloudStorageAuditReport(
            provider: config.provider,
            bucketName: config.bucketName,
            endpointURL: config.endpointURL.absoluteString,
            isCompliant: compliant,
            securityScore: score,
            violations: violations
        )
    }

    public static func formatCloudStorageAuditReportMarkdown(_ report: CloudStorageAuditReport) -> String {
        var md = "### ☁️ Cloud Object Storage & Artifact Export Audit\n\n"
        md += "| Parameter | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Provider | `\(report.provider.rawValue)` | 🏢 Infrastructure |\n"
        md += "| Bucket | `\(report.bucketName)` | 📦 Target Container |\n"
        md += "| Endpoint | `\(report.endpointURL)` | 🌐 Connection URL |\n"
        md += "| Compliance | \(report.isCompliant ? "✅ Approved" : "❌ Non-Compliant") | Security Perimeter |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Solid" : "⚠️ Attention Required") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
