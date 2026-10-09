import Foundation
import CryptoKit

// MARK: - MetricKit Telemetry Anonymizer & Crash Report Packager (Batch 57)

/// Metadata header for packaged crash diagnostics.
public struct CrashReportMetadata: Codable, Sendable, Equatable {
    public let reportId: String
    public let generatedAt: Date
    public let appVersion: String
    public let osVersion: String
    public let deviceArchitecture: String

    public init(
        reportId: String = UUID().uuidString,
        generatedAt: Date = Date(),
        appVersion: String,
        osVersion: String,
        deviceArchitecture: String = "arm64"
    ) {
        self.reportId = reportId
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceArchitecture = deviceArchitecture
    }
}

/// A sanitized, PII-scrubbed diagnostic observation.
public struct AnonymizedDiagnosticEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let occurredAt: Date
    public let kind: FieldDiagnosticKind
    public let terminationCategory: String?
    public let signal: Int?
    public let exceptionCode: UInt64?
    public let hangDurationSeconds: Double?
    public let cpuTimeSeconds: Double?
    public let diskBytesWritten: Int64?

    public init(
        id: String,
        occurredAt: Date,
        kind: FieldDiagnosticKind,
        terminationCategory: String? = nil,
        signal: Int? = nil,
        exceptionCode: UInt64? = nil,
        hangDurationSeconds: Double? = nil,
        cpuTimeSeconds: Double? = nil,
        diskBytesWritten: Int64? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.terminationCategory = terminationCategory
        self.signal = signal
        self.exceptionCode = exceptionCode
        self.hangDurationSeconds = hangDurationSeconds
        self.cpuTimeSeconds = cpuTimeSeconds
        self.diskBytesWritten = diskBytesWritten
    }
}

/// A self-contained, cryptographically digested diagnostic bundle.
public struct CrashReportBundle: Codable, Sendable, Equatable {
    public let metadata: CrashReportMetadata
    public let entries: [AnonymizedDiagnosticEntry]
    public let sha256Digest: String
    public let bundleSignature: String

    public init(
        metadata: CrashReportMetadata,
        entries: [AnonymizedDiagnosticEntry],
        sha256Digest: String,
        bundleSignature: String
    ) {
        self.metadata = metadata
        self.entries = entries
        self.sha256Digest = sha256Digest
        self.bundleSignature = bundleSignature
    }

    /// Serializes bundle to pretty-printed JSON.
    public func toJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    public func toMarkdown() -> String {
        var lines: [String] = [
            "## Packaged Crash & Diagnostic Bundle",
            "",
            "- **Report ID**: `\(metadata.reportId)`",
            "- **App Version**: `\(metadata.appVersion)`",
            "- **OS Platform**: `\(metadata.osVersion)` (`\(metadata.deviceArchitecture)`)",
            "- **SHA-256 Digest**: `\(sha256Digest)`",
            "- **Signature**: `\(bundleSignature.prefix(16))...`",
            "- **Diagnostic Observations**: `\(entries.count)`",
            "",
            "| Kind | Occurred At | Termination / Details | Signal / Code |",
            "| :--- | :--- | :--- | :---: |"
        ]

        for e in entries {
            var detail = e.terminationCategory ?? "-"
            if let hang = e.hangDurationSeconds {
                detail = "Hang \(String(format: "%.2fs", hang))"
            } else if let cpu = e.cpuTimeSeconds {
                detail = "CPU \(String(format: "%.2fs", cpu))"
            }

            var code = "-"
            if let sig = e.signal {
                code = "SIG\(sig)"
            } else if let exc = e.exceptionCode {
                code = "0x\(String(exc, radix: 16))"
            }

            lines.append("| `\(e.kind.rawValue)` | `\(e.occurredAt)` | \(detail) | `\(code)` |")
        }

        return lines.joined(separator: "\n")
    }
}

/// Anonymizes MetricKit telemetry payloads and packages them into signed bundles.
public enum CrashReportPackager {
    private static let userHomeRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: #"/Users/[^/\s]+"#, options: [])) ?? NSRegularExpression()
    }()

    private static let ipAddressRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: #"\b(?:10|127|172\.(?:1[6-9]|2[0-9]|3[01])|192\.168)\.\d{1,3}\.\d{1,3}\b"#, options: [])) ?? NSRegularExpression()
    }()

    private static let apiKeyRegex: NSRegularExpression = {
        (try? NSRegularExpression(pattern: #"\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{30,})\b"#, options: [])) ?? NSRegularExpression()
    }()

    /// Anonymizes filesystem paths by removing local usernames.
    public static func anonymizePath(_ path: String) -> String {
        let range = NSRange(path.startIndex..<path.endIndex, in: path)
        return userHomeRegex.stringByReplacingMatches(in: path, options: [], range: range, withTemplate: "/Users/<anonymized>")
    }

    /// Scrubs PII, user paths, private IP addresses, and secret tokens from arbitrary diagnostic text.
    public static func scrubText(_ text: String) -> String {
        var result = anonymizePath(text)
        let ipRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = ipAddressRegex.stringByReplacingMatches(in: result, options: [], range: ipRange, withTemplate: "[REDACTED_IP]")
        let secretRange = NSRange(result.startIndex..<result.endIndex, in: result)
        result = apiKeyRegex.stringByReplacingMatches(in: result, options: [], range: secretRange, withTemplate: "[REDACTED_SECRET]")
        return result
    }

    /// Sanitizes an individual `MetricDiagnosticPayload`.
    public static func sanitizePayload(_ payload: MetricDiagnosticPayload) -> AnonymizedDiagnosticEntry {
        let sanitizedCategory = payload.terminationCategory.map { scrubText($0) }

        return AnonymizedDiagnosticEntry(
            id: payload.id.uuidString,
            occurredAt: payload.occurredAt,
            kind: payload.kind,
            terminationCategory: sanitizedCategory,
            signal: payload.signal,
            exceptionCode: payload.exceptionCode,
            hangDurationSeconds: payload.hangDurationSeconds,
            cpuTimeSeconds: payload.cpuTimeSeconds,
            diskBytesWritten: payload.diskBytesWritten
        )
    }

    /// Computes deterministic SHA-256 digest of anonymized diagnostic entries.
    public static func computeDigest(entries: [AnonymizedDiagnosticEntry]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else {
            return ""
        }
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Packages diagnostic observations into a signed crash report bundle.
    public static func package(
        payloads: [MetricDiagnosticPayload],
        appVersion: String = "1.0.0",
        osVersion: String = "macOS 27.0",
        signingKey: String? = nil
    ) -> CrashReportBundle {
        let sanitizedEntries = payloads.map { sanitizePayload($0) }
        let digest = computeDigest(entries: sanitizedEntries)

        // Generate HMAC signature if signing key is provided; otherwise deterministic bundle signature
        let signature: String
        let keyData = (signingKey ?? "apex-default-telemetry-signing-key").data(using: .utf8) ?? Data()
        let symmetricKey = SymmetricKey(data: keyData)
        let hmac = HMAC<SHA256>.authenticationCode(for: digest.data(using: .utf8) ?? Data(), using: symmetricKey)
        signature = hmac.compactMap { String(format: "%02x", $0) }.joined()

        let metadata = CrashReportMetadata(
            appVersion: appVersion,
            osVersion: osVersion
        )

        return CrashReportBundle(
            metadata: metadata,
            entries: sanitizedEntries,
            sha256Digest: digest,
            bundleSignature: signature
        )
    }

    /// Validates the SHA-256 digest and HMAC signature of a packaged report bundle.
    public static func verify(bundle: CrashReportBundle, signingKey: String? = nil) -> Bool {
        let recalculatedDigest = computeDigest(entries: bundle.entries)
        guard recalculatedDigest == bundle.sha256Digest, !recalculatedDigest.isEmpty else {
            return false
        }

        let keyData = (signingKey ?? "apex-default-telemetry-signing-key").data(using: .utf8) ?? Data()
        let symmetricKey = SymmetricKey(data: keyData)
        let expectedHMAC = HMAC<SHA256>.authenticationCode(for: recalculatedDigest.data(using: .utf8) ?? Data(), using: symmetricKey)
        let expectedSignature = expectedHMAC.compactMap { String(format: "%02x", $0) }.joined()

        return expectedSignature == bundle.bundleSignature
    }
}
