import CryptoKit
import Foundation

// MARK: - SLSA v1.0 Build Provenance, Binary SHA-256 Checksum Manifest & Notarization Verifier (Batch 44)

/// A single artifact or manifest file with its verified SHA-256 digest.
public struct ProvenanceSubject: Sendable, Equatable, Codable {
    public let name: String
    public let sha256: String
    public let sizeBytes: Int

    public init(name: String, sha256: String, sizeBytes: Int) {
        self.name = name
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// Result of auditing macOS release signing and Apple Notary Service readiness.
public struct NotarizationReadinessReport: Sendable, Equatable, Codable {
    public let passed: Bool
    public let hardenedRuntimeCompatible: Bool
    public let getTaskAllowPresent: Bool
    public let findings: [String]

    public init(
        passed: Bool,
        hardenedRuntimeCompatible: Bool,
        getTaskAllowPresent: Bool,
        findings: [String]
    ) {
        self.passed = passed
        self.hardenedRuntimeCompatible = hardenedRuntimeCompatible
        self.getTaskAllowPresent = getTaskAllowPresent
        self.findings = findings
    }
}

/// Complete SLSA v1.0 provenance attestation and checksum bundle.
public struct SLSAProvenanceAttestation: Sendable, Equatable, Codable {
    public static let statementType = "https://in-toto.io/Statement/v1"
    public static let predicateType = "https://slsa.dev/provenance/v1"
    public static let defaultBuilderID = "https://github.com/dboone323/ApexAgent/.github/workflows/swift.yml"

    public let subjects: [ProvenanceSubject]
    public let gitCommitSHA: String
    public let gitBranch: String
    public let packageResolvedSHA256: String
    public let builderID: String
    public let notarizationReport: NotarizationReadinessReport

    public init(
        subjects: [ProvenanceSubject],
        gitCommitSHA: String,
        gitBranch: String,
        packageResolvedSHA256: String,
        builderID: String = SLSAProvenanceAttestation.defaultBuilderID,
        notarizationReport: NotarizationReadinessReport
    ) {
        self.subjects = subjects
        self.gitCommitSHA = gitCommitSHA
        self.gitBranch = gitBranch
        self.packageResolvedSHA256 = packageResolvedSHA256
        self.builderID = builderID
        self.notarizationReport = notarizationReport
    }

    /// Formats a standard `shasum -a 256 -c` compatible checksum manifest (`<sha256>  <name>`).
    public func toSHA256SumsText() -> String {
        subjects
            .map { "\($0.sha256)  \($0.name)" }
            .joined(separator: "\n")
    }

    /// Exports an in-toto v1 / SLSA v1.0 provenance JSON statement.
    public func toSLSAJSON() -> String {
        let subjectList: [[String: Any]] = subjects.map {
            [
                "name": $0.name,
                "digest": ["sha256": $0.sha256],
            ]
        }

        let statement: [String: Any] = [
            "_type": Self.statementType,
            "predicateType": Self.predicateType,
            "subject": subjectList,
            "predicate": [
                "buildDefinition": [
                    "buildType": "https://slsa.dev/container-based-build/v1",
                    "externalParameters": [
                        "repository": "https://github.com/dboone323/ApexAgent",
                        "ref": gitBranch,
                        "commitSHA": gitCommitSHA,
                    ],
                    "resolvedDependencies": [
                        [
                            "uri": "file://Package.resolved",
                            "digest": ["sha256": packageResolvedSHA256],
                        ]
                    ],
                ],
                "runDetails": [
                    "builder": [
                        "id": builderID
                    ],
                    "notarizationReady": notarizationReport.passed,
                ],
            ],
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: statement,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    public func toMarkdown() -> String {
        let badge = notarizationReport.passed ? "PASS" : "FAIL"
        var lines: [String] = [
            "## SLSA v1.0 Build Provenance & Notarization Readiness (`\(badge)`)",
            "",
            "- **Statement Type**: `\(Self.statementType)`",
            "- **Predicate Type**: `\(Self.predicateType)`",
            "- **Git Commit**: `\(gitCommitSHA)` (`\(gitBranch)`)",
            "- **`Package.resolved` SHA-256**: `\(packageResolvedSHA256)`",
            "- **Notarization Ready**: `\(notarizationReport.passed ? "YES" : "NO")`",
            "",
            "### Verified Subjects (\(subjects.count))",
            "| Artifact / Manifest | Size (B) | SHA-256 Digest |",
            "| :--- | :---: | :--- |",
        ]
        for subject in subjects {
            lines.append("| `\(subject.name)` | \(subject.sizeBytes) | `\(subject.sha256)` |")
        }
        if !notarizationReport.findings.isEmpty {
            lines.append("")
            lines.append("### Notarization Findings")
            for finding in notarizationReport.findings {
                lines.append("- \(finding)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

public enum ReleaseProvenanceGenerator {
    /// Computes the lowercase hexadecimal SHA-256 digest of raw `Data` using `CryptoKit`.
    public static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes a `ProvenanceSubject` for a file on disk at `fileURL` using `relativeName`.
    public static func subject(forFileAt fileURL: URL, relativeName: String) throws -> ProvenanceSubject {
        let data = try Data(contentsOf: fileURL)
        return ProvenanceSubject(
            name: relativeName,
            sha256: sha256Hex(of: data),
            sizeBytes: data.count
        )
    }

    /// Audits macOS entitlements and `Info.plist` for Hardened Runtime and Apple Notary Service compatibility.
    public static func auditNotarizationReadiness(
        entitlementsData: Data,
        infoPlistData: Data,
        forReleaseDistribution: Bool = false
    ) -> NotarizationReadinessReport {
        var findings: [String] = []
        var getTaskAllowPresent = false

        guard let entDict = (try? PropertyListSerialization.propertyList(from: entitlementsData, options: [], format: nil)) as? [String: Any] else {
            return NotarizationReadinessReport(
                passed: false,
                hardenedRuntimeCompatible: false,
                getTaskAllowPresent: false,
                findings: ["Entitlements payload is not a valid XML dictionary property list."]
            )
        }

        if (entDict["com.apple.security.get-task-allow"] as? Bool) == true {
            getTaskAllowPresent = true
            if forReleaseDistribution {
                findings.append(
                    "Release distribution archive must not include com.apple.security.get-task-allow=true (Apple Notary Service rejects debuggable binaries)."
                )
            }
        }

        if (entDict["com.apple.security.cs.disable-library-validation"] as? Bool) == true
            && (entDict["com.apple.security.cs.allow-Arbitrary-Loads"] as? Bool) == true {
            findings.append("Suspicious combination of disabled library validation and arbitrary loads in entitlements.")
        }

        guard let infoDict = (try? PropertyListSerialization.propertyList(from: infoPlistData, options: [], format: nil)) as? [String: Any] else {
            return NotarizationReadinessReport(
                passed: false,
                hardenedRuntimeCompatible: false,
                getTaskAllowPresent: getTaskAllowPresent,
                findings: findings + ["Info.plist payload is not a valid XML dictionary property list."]
            )
        }

        for requiredKey in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion"] {
            let val = (infoDict[requiredKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if val.isEmpty {
                findings.append("Info.plist is missing required notarization key '\(requiredKey)'.")
            }
        }

        return NotarizationReadinessReport(
            passed: findings.isEmpty,
            hardenedRuntimeCompatible: findings.isEmpty,
            getTaskAllowPresent: getTaskAllowPresent,
            findings: findings
        )
    }

    /// Generates a real SLSA v1.0 provenance attestation for the repository at `rootURL`.
    public static func generateRepositoryProvenance(
        atRepoRoot rootURL: URL,
        forReleaseDistribution: Bool = false
    ) -> SLSAProvenanceAttestation {
        let trackedPaths = [
            "Package.swift",
            "Package.resolved",
            "project.yml",
            "ApexAgent/Info.plist",
            "ApexAgent/ApexAgent.entitlements",
            "ApexAgent/Resources/PrivacyInfo.xcprivacy",
        ]

        var subjects: [ProvenanceSubject] = []
        var packageResolvedHash = String(repeating: "0", count: 64)

        for relPath in trackedPaths {
            let fileURL = rootURL.appendingPathComponent(relPath)
            if let subj = try? subject(forFileAt: fileURL, relativeName: relPath) {
                subjects.append(subj)
                if relPath == "Package.resolved" {
                    packageResolvedHash = subj.sha256
                }
            }
        }

        let entData = (try? Data(contentsOf: rootURL.appendingPathComponent("ApexAgent/ApexAgent.entitlements"))) ?? Data()
        let infoData = (try? Data(contentsOf: rootURL.appendingPathComponent("ApexAgent/Info.plist"))) ?? Data()
        let notarization = auditNotarizationReadiness(
            entitlementsData: entData,
            infoPlistData: infoData,
            forReleaseDistribution: forReleaseDistribution
        )

        let commitSHA = runGit(at: rootURL, args: ["rev-parse", "HEAD"]) ?? "unknown"
        let branch = runGit(at: rootURL, args: ["rev-parse", "--abbrev-ref", "HEAD"]) ?? "main"

        return SLSAProvenanceAttestation(
            subjects: subjects,
            gitCommitSHA: commitSHA,
            gitBranch: branch,
            packageResolvedSHA256: packageResolvedHash,
            notarizationReport: notarization
        )
    }

    private static func runGit(at rootURL: URL, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootURL.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
