import Foundation

// MARK: - Batch 36: Supply-Chain Dependency Pinning & SBOM Auditor

/// A single pinned dependency parsed from `Package.resolved` (v2/v3).
public struct LockedDependencyPin: Codable, Sendable, Equatable {
    public let identity: String
    public let kind: String
    public let location: String
    public let version: String?
    public let revision: String
    public let branch: String?

    public init(
        identity: String,
        kind: String = "remoteSourceControl",
        location: String,
        version: String?,
        revision: String,
        branch: String? = nil
    ) {
        self.identity = identity
        self.kind = kind
        self.location = location
        self.version = version
        self.revision = revision
        self.branch = branch
    }

    /// Package URL (purl) representation for CycloneDX SBOM export.
    public var packageURL: String {
        let ver = version ?? String(revision.prefix(12))
        return "pkg:swift/\(identity)@\(ver)"
    }
}

/// Classification of supply-chain or dependency lockfile violations.
public enum DependencyLockViolationKind: String, Codable, Sendable, CaseIterable {
    case invalidLockSchema
    case insecureRepositoryURL
    case untrustedRepositoryOwner
    case floatingBranchPin
    case invalidCommitRevision
    case manifestVersionMismatch
}

/// A single supply-chain or version-pinning violation.
public struct DependencyLockViolation: Codable, Sendable, Equatable {
    public let kind: DependencyLockViolationKind
    public let identity: String
    public let message: String

    public init(kind: DependencyLockViolationKind, identity: String, message: String) {
        self.kind = kind
        self.identity = identity
        self.message = message
    }
}

/// Complete supply-chain audit and SBOM report produced by ``DependencyLockAuditor``.
public struct DependencyLockAuditReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let pins: [LockedDependencyPin]
    public let violations: [DependencyLockViolation]
    public let checkedFiles: [String]

    public init(
        passed: Bool,
        pins: [LockedDependencyPin],
        violations: [DependencyLockViolation],
        checkedFiles: [String]
    ) {
        self.passed = passed
        self.pins = pins
        self.violations = violations
        self.checkedFiles = checkedFiles
    }

    public func formatSummary() -> String {
        if passed {
            return "PASS: Dependency lock audit clean (\(pins.count) pinned packages verified across \(checkedFiles.joined(separator: ", ")))."
        }
        var lines = [
            "FAIL: Dependency lock audit found \(violations.count) violation(s) across \(pins.count) package(s):"
        ]
        for v in violations {
            lines.append("  [\(v.kind.rawValue)] \(v.identity) — \(v.message)")
        }
        return lines.joined(separator: "\n")
    }

    /// Exports a CycloneDX 1.5 compatible JSON Software Bill of Materials (SBOM).
    public func exportCycloneDXJSON() -> String {
        struct CycloneComponent: Codable {
            let type: String
            let name: String
            let version: String
            let purl: String
            let externalReferences: [[String: String]]
            let properties: [[String: String]]
        }
        struct CycloneBOM: Codable {
            let bomFormat: String
            let specVersion: String
            let version: Int
            let components: [CycloneComponent]
        }

        let components = pins.sorted { $0.identity < $1.identity }.map { pin in
            CycloneComponent(
                type: "library",
                name: pin.identity,
                version: pin.version ?? "unversioned",
                purl: pin.packageURL,
                externalReferences: [
                    ["type": "vcs", "url": pin.location]
                ],
                properties: [
                    ["name": "swiftpm:revision", "value": pin.revision],
                    ["name": "swiftpm:kind", "value": pin.kind]
                ]
            )
        }
        let bom = CycloneBOM(
            bomFormat: "CycloneDX",
            specVersion: "1.5",
            version: 1,
            components: components
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(bom),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"bomFormat\":\"CycloneDX\",\"specVersion\":\"1.5\",\"version\":1,\"components\":[]}"
        }
        return json
    }

    /// Exports a Markdown Software Bill of Materials (SBOM) table.
    public func exportSBOMMarkdown() -> String {
        var md = "### 📦 ApexAgent Software Bill of Materials (\(pins.count) Locked Dependencies)\n\n"
        md += "| Package Identity | Version | Commit SHA (short) | Upstream Repository |\n"
        md += "|---|---|---|---|\n"
        for pin in pins.sorted(by: { $0.identity < $1.identity }) {
            let ver = pin.version ?? "branch:\(pin.branch ?? "unknown")"
            let shortRev = String(pin.revision.prefix(10))
            md += "| `\(pin.identity)` | `\(ver)` | `\(shortRev)` | `\(pin.location)` |\n"
        }
        return md
    }
}

/// Supply-chain dependency lockfile verifier and SBOM generator.
public enum DependencyLockAuditor {

    /// Trusted upstream GitHub organizations allowed in `Package.resolved`.
    public static let allowedGitHubOrganizations: Set<String> = [
        "apple",
        "grpc",
        "swift-server",
        "facebook"
    ]

    /// Parses a SwiftPM `Package.resolved` (v2 or v3) JSON document into ``LockedDependencyPin`` entries.
    public static func parsePackageResolved(_ jsonString: String) throws -> [LockedDependencyPin] {
        guard let data = jsonString.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        guard let version = root["version"] as? Int, (version == 2 || version == 3),
              let rawPins = root["pins"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }

        var result: [LockedDependencyPin] = []
        for raw in rawPins {
            guard let identity = raw["identity"] as? String,
                  let location = raw["location"] as? String,
                  let state = raw["state"] as? [String: Any],
                  let revision = state["revision"] as? String else {
                throw CocoaError(.coderReadCorrupt)
            }
            let kind = (raw["kind"] as? String) ?? "remoteSourceControl"
            let pinVersion = state["version"] as? String
            let branch = state["branch"] as? String
            result.append(
                LockedDependencyPin(
                    identity: identity,
                    kind: kind,
                    location: location,
                    version: pinVersion,
                    revision: revision,
                    branch: branch
                )
            )
        }
        return result
    }

    /// Audits an array of locked pins for HTTPS transport, allowed GitHub organization, exact semantic version, and 40-char hex SHA-1 revision.
    public static func auditPins(
        _ pins: [LockedDependencyPin],
        allowedOrgs: Set<String> = allowedGitHubOrganizations
    ) -> [DependencyLockViolation] {
        var violations: [DependencyLockViolation] = []
        let normalizedOrgs = Set(allowedOrgs.map { $0.lowercased() })

        for pin in pins {
            // 1. HTTPS transport required
            if !pin.location.lowercased().hasPrefix("https://") {
                violations.append(
                    DependencyLockViolation(
                        kind: .insecureRepositoryURL,
                        identity: pin.identity,
                        message: "Dependency URL '\(pin.location)' must use HTTPS."
                    )
                )
            }

            // 2. Trusted GitHub organization check
            if let org = extractGitHubOrganization(from: pin.location) {
                if !normalizedOrgs.contains(org.lowercased()) {
                    violations.append(
                        DependencyLockViolation(
                            kind: .untrustedRepositoryOwner,
                            identity: pin.identity,
                            message: "GitHub organization '\(org)' is not in the allowlist (\(normalizedOrgs.sorted().joined(separator: ", ")))."
                        )
                    )
                }
            } else {
                violations.append(
                    DependencyLockViolation(
                        kind: .untrustedRepositoryOwner,
                        identity: pin.identity,
                        message: "Cannot verify repository owner for '\(pin.location)'."
                    )
                )
            }

            // 3. No floating branch pins; semantic version required
            if let branch = pin.branch, !branch.isEmpty {
                violations.append(
                    DependencyLockViolation(
                        kind: .floatingBranchPin,
                        identity: pin.identity,
                        message: "Floating branch pin '\(branch)' is forbidden; pin to an exact release version."
                    )
                )
            }
            if pin.version == nil || pin.version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                violations.append(
                    DependencyLockViolation(
                        kind: .floatingBranchPin,
                        identity: pin.identity,
                        message: "Missing semantic release version in Package.resolved state."
                    )
                )
            }

            // 4. 40-character lowercase hex revision SHA
            if !isValidSHA1Revision(pin.revision) {
                violations.append(
                    DependencyLockViolation(
                        kind: .invalidCommitRevision,
                        identity: pin.identity,
                        message: "Invalid commit revision '\(pin.revision)'; expected 40 lowercase hex characters."
                    )
                )
            }
        }
        return violations
    }

    /// Verifies that direct dependencies declared with `exact:` in `Package.swift` and `exactVersion:` in `project.yml`
    /// match each other and match `Package.resolved`.
    public static func auditManifestParity(
        pins: [LockedDependencyPin],
        packageSwift: String,
        projectYML: String
    ) -> [DependencyLockViolation] {
        var violations: [DependencyLockViolation] = []
        let pinMap = Dictionary(uniqueKeysWithValues: pins.map { ($0.identity.lowercased(), $0) })

        let packageDeps = extractPackageSwiftExactDependencies(from: packageSwift)
        let projectDeps = extractProjectYMLExactDependencies(from: projectYML)

        for (identity, pkgVersion) in packageDeps.sorted(by: { $0.key < $1.key }) {
            guard let locked = pinMap[identity] else {
                violations.append(
                    DependencyLockViolation(
                        kind: .manifestVersionMismatch,
                        identity: identity,
                        message: "Direct dependency '\(identity)' (exact: \(pkgVersion)) in Package.swift is missing from Package.resolved."
                    )
                )
                continue
            }
            if locked.version != pkgVersion {
                violations.append(
                    DependencyLockViolation(
                        kind: .manifestVersionMismatch,
                        identity: identity,
                        message: "Package.swift pins '\(identity)' to \(pkgVersion), but Package.resolved has \(locked.version ?? "nil")."
                    )
                )
            }
            if let ymlVersion = projectDeps[identity], ymlVersion != pkgVersion {
                violations.append(
                    DependencyLockViolation(
                        kind: .manifestVersionMismatch,
                        identity: identity,
                        message: "project.yml pins '\(identity)' to \(ymlVersion), but Package.swift pins \(pkgVersion)."
                    )
                )
            } else if projectDeps[identity] == nil {
                violations.append(
                    DependencyLockViolation(
                        kind: .manifestVersionMismatch,
                        identity: identity,
                        message: "Direct dependency '\(identity)' in Package.swift is missing from project.yml packages."
                    )
                )
            }
        }
        return violations
    }

    /// Runs a full supply-chain lock and manifest parity audit on `repoRoot`.
    public static func auditRepository(atRepoRoot repoRoot: URL) -> DependencyLockAuditReport {
        let resolvedRel = "Package.resolved"
        let packageRel = "Package.swift"
        let projectRel = "project.yml"

        let resolvedURL = repoRoot.appendingPathComponent(resolvedRel)
        let packageURL = repoRoot.appendingPathComponent(packageRel)
        let projectURL = repoRoot.appendingPathComponent(projectRel)

        guard let resolvedText = try? String(contentsOf: resolvedURL, encoding: .utf8),
              let pins = try? parsePackageResolved(resolvedText) else {
            let violation = DependencyLockViolation(
                kind: .invalidLockSchema,
                identity: "Package.resolved",
                message: "Unable to parse Package.resolved (v2/v3 schema required)."
            )
            return DependencyLockAuditReport(
                passed: false,
                pins: [],
                violations: [violation],
                checkedFiles: [resolvedRel]
            )
        }

        let packageText = (try? String(contentsOf: packageURL, encoding: .utf8)) ?? ""
        let projectText = (try? String(contentsOf: projectURL, encoding: .utf8)) ?? ""

        let pinViolations = auditPins(pins)
        let parityViolations = auditManifestParity(
            pins: pins,
            packageSwift: packageText,
            projectYML: projectText
        )
        let allViolations = pinViolations + parityViolations

        return DependencyLockAuditReport(
            passed: allViolations.isEmpty,
            pins: pins,
            violations: allViolations,
            checkedFiles: [resolvedRel, packageRel, projectRel]
        )
    }

    // MARK: - Private Helpers

    private static func extractGitHubOrganization(from location: String) -> String? {
        guard let url = URL(string: location),
              let host = url.host?.lowercased(),
              host == "github.com" else {
            return nil
        }
        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard segments.count >= 2 else { return nil }
        return segments[0]
    }

    private static func isValidSHA1Revision(_ value: String) -> Bool {
        guard value.count == 40 else { return false }
        for scalar in value.unicodeScalars {
            let v = scalar.value
            let isDigit = (v >= 0x30 && v <= 0x39)
            let isLowerHex = (v >= 0x61 && v <= 0x66)
            if !isDigit && !isLowerHex { return false }
        }
        return true
    }

    private static func extractPackageSwiftExactDependencies(from source: String) -> [String: String] {
        // Matches: .package(url: "https://github.com/org/<identity>.git", exact: "<version>")
        let pattern = #"\.package\(\s*url:\s*"https://github\.com/[^/]+/([^."/]+)(?:\.git)?"\s*,\s*exact:\s*"([^"]+)"\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        var result: [String: String] = [:]
        for match in regex.matches(in: source, options: [], range: nsRange) {
            guard match.numberOfRanges == 3,
                  let idRange = Range(match.range(at: 1), in: source),
                  let verRange = Range(match.range(at: 2), in: source) else { continue }
            result[String(source[idRange]).lowercased()] = String(source[verRange])
        }
        return result
    }

    private static func extractProjectYMLExactDependencies(from yml: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentIdentity: String?
        for line in yml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("url:") {
                let rawURL = trimmed.replacingOccurrences(of: "url:", with: "").trimmingCharacters(in: .whitespaces)
                if let lastSeg = rawURL.split(separator: "/").last {
                    let clean = String(lastSeg).replacingOccurrences(of: ".git", with: "").lowercased()
                    currentIdentity = clean
                }
            } else if trimmed.hasPrefix("exactVersion:"), let id = currentIdentity {
                let ver = trimmed.replacingOccurrences(of: "exactVersion:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "\"", with: "")
                result[id] = ver
                currentIdentity = nil
            }
        }
        return result
    }
}
