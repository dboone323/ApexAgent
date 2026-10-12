//
//  CloudStorageAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 108: Cloud Storage Artifact Export & Presigned URL Tests.
//

import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 108 — Cloud Storage & Presigned URL Security Auditor Tests")
struct CloudStorageAuditorTests {

    @Test("Valid S3 and R2 export configurations pass audit with 100% compliance")
    func testValidExportConfigurationsPass() {
        let s3Config = CloudStorageExportConfig(
            provider: .s3,
            endpointURL: URL(string: "https://s3.us-west-2.amazonaws.com")!,
            bucketName: "apex-production-artifacts",
            defaultExpirationSeconds: 3600,
            maxAllowedExpirationSeconds: 86400,
            requireServerSideEncryption: true
        )

        let report = CloudStorageAuditor.auditConfiguration(s3Config)
        #expect(report.isCompliant)
        #expect(report.securityScore >= 0.95)
        #expect(report.violations.isEmpty)

        let r2Config = CloudStorageExportConfig(
            provider: .r2,
            endpointURL: URL(string: "https://abcdef123456.r2.cloudflarestorage.com")!,
            bucketName: "agent-blobs",
            requireServerSideEncryption: true
        )
        let r2Report = CloudStorageAuditor.auditConfiguration(r2Config)
        #expect(r2Report.isCompliant)
    }

    @Test("Insecure HTTP remote endpoint trips fatal security violation")
    func testInsecureEndpointTripsFatal() {
        let config = CloudStorageExportConfig(
            provider: .s3,
            endpointURL: URL(string: "http://s3.amazonaws.com")!,
            bucketName: "my-bucket"
        )

        let report = CloudStorageAuditor.auditConfiguration(config)
        #expect(!report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_STORAGE_ENDPOINT" && $0.isFatal }))
    }

    @Test("Localhost HTTP endpoint permitted for MinIO development")
    func testMinIOLocalhostAllowed() {
        let config = CloudStorageExportConfig(
            provider: .minio,
            endpointURL: URL(string: "http://127.0.0.1:9000")!,
            bucketName: "local-minio-bucket"
        )

        let report = CloudStorageAuditor.auditConfiguration(config)
        #expect(report.isCompliant)
        #expect(report.violations.contains(where: { $0.code == "LOCAL_MINIO_HTTP_ALLOWED" && !$0.isFatal }))
    }

    @Test("Bucket name validator rejects uppercase, consecutive dots, and invalid lengths")
    func testBucketNameValidation() {
        #expect(CloudStorageAuditor.auditBucketName("valid-bucket-name-123").isEmpty)

        let upperViolations = CloudStorageAuditor.auditBucketName("MyBucketName")
        #expect(upperViolations.contains(where: { $0.code == "UPPERCASE_IN_BUCKET_NAME" }))

        let dotViolations = CloudStorageAuditor.auditBucketName("invalid..bucket")
        #expect(dotViolations.contains(where: { $0.code == "CONSECUTIVE_DOTS_IN_BUCKET" }))

        let shortViolations = CloudStorageAuditor.auditBucketName("ab")
        #expect(shortViolations.contains(where: { $0.code == "INVALID_BUCKET_LENGTH" }))
    }

    @Test("Object key auditor detects path traversal attacks and leading slash")
    func testObjectKeyAuditing() {
        #expect(CloudStorageAuditor.auditObjectKey("reports/2026/summary.pdf").isEmpty)

        let traversal = CloudStorageAuditor.auditObjectKey("../../../etc/passwd")
        #expect(traversal.contains(where: { $0.code == "PATH_TRAVERSAL_IN_KEY" && $0.isFatal }))

        let urlEncodedTraversal = CloudStorageAuditor.auditObjectKey("artifacts/%2e%2e/secret.key")
        #expect(urlEncodedTraversal.contains(where: { $0.code == "PATH_TRAVERSAL_IN_KEY" }))

        let leadingSlash = CloudStorageAuditor.auditObjectKey("/artifacts/data.json")
        #expect(leadingSlash.contains(where: { $0.code == "LEADING_SLASH_IN_KEY" && !$0.isFatal }))
    }

    @Test("SignedURLVerifier validates active SigV4 presigned URL and detects expired or excessive lifespan")
    func testPresignedURLVerification() {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let dateStr = formatter.string(from: now)

        let validURL = URL(string: "https://my-bucket.s3.amazonaws.com/test.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20261012%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=\(dateStr)&X-Amz-Expires=3600&X-Amz-SignedHeaders=host&X-Amz-Signature=abcdef1234567890")!

        let activeResult = SignedURLVerifier.verifySigV4URL(url: validURL, currentDate: now)
        #expect(activeResult.isValid)
        #expect(!activeResult.isExpired)
        #expect(activeResult.expirationSeconds == 3600)
        #expect(activeResult.algorithm == "AWS4-HMAC-SHA256")

        // Expired check (current date 2 hours ahead)
        let futureDate = now.addingTimeInterval(7200)
        let expiredResult = SignedURLVerifier.verifySigV4URL(url: validURL, currentDate: futureDate)
        #expect(!expiredResult.isValid)
        #expect(expiredResult.isExpired)

        // Excessive expiration (e.g. 100,000s > 86,400s)
        let excessiveURL = URL(string: "https://my-bucket.s3.amazonaws.com/test.zip?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Date=\(dateStr)&X-Amz-Expires=100000&X-Amz-Signature=sig")!
        let excessiveResult = SignedURLVerifier.verifySigV4URL(url: excessiveURL, maxAllowedExpirationSeconds: 86400, currentDate: now)
        #expect(!excessiveResult.isValid)
        #expect(excessiveResult.reason?.contains("exceeds security ceiling") == true)
    }

    @Test("formatCloudStorageAuditReportMarkdown renders markdown audit report")
    func testMarkdownFormatting() {
        let report = CloudStorageAuditReport(
            provider: .s3,
            bucketName: "apex-artifacts",
            endpointURL: "https://s3.amazonaws.com",
            isCompliant: true,
            securityScore: 1.0,
            violations: []
        )
        let md = CloudStorageAuditor.formatCloudStorageAuditReportMarkdown(report)
        #expect(md.contains("### ☁️ Cloud Object Storage & Artifact Export Audit"))
        #expect(md.contains("apex-artifacts"))
        #expect(md.contains("100%"))
        #expect(md.contains("Amazon S3"))
    }
}
