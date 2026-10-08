import Foundation

// MARK: - Batch 39: Entitlements, Weak-Linked Frameworks & Build-Graph Parity Verifier

/// Classification of bundle, entitlement, or build-graph integrity issues.
public enum BundleIntegrityIssueKind: String, Codable, Sendable, CaseIterable {
    case missingRequiredEntitlement
    case unexpectedEntitlementValue
    case missingInfoPlistKey
    case missingURLSchemeRegistration
    case missingWeakFrameworkFlag
    case missingRpathOrSigningConfig
}

/// A single bundle, entitlement, or build-graph integrity finding.
public struct BundleIntegrityIssue: Codable, Sendable, Equatable {
    public let kind: BundleIntegrityIssueKind
    public let file: String
    public let message: String

    public init(kind: BundleIntegrityIssueKind, file: String, message: String) {
        self.kind = kind
        self.file = file
        self.message = message
    }
}

/// Complete audit report from ``BundleIntegrityVerifier``.
public struct BundleIntegrityReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let issues: [BundleIntegrityIssue]
    public let checkedFiles: [String]

    public init(passed: Bool, issues: [BundleIntegrityIssue], checkedFiles: [String]) {
        self.passed = passed
        self.issues = issues
        self.checkedFiles = checkedFiles
    }

    public func formatSummary() -> String {
        if passed {
            return "PASS: Bundle entitlements, Info.plist URL schemes, and build-graph weak-link parity verified (\(checkedFiles.joined(separator: ", ")))."
        }
        var lines = [
            "FAIL: Bundle integrity verifier found \(issues.count) issue(s):"
        ]
        for issue in issues {
            lines.append("  [\(issue.kind.rawValue)] \(issue.file) — \(issue.message)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Verifies `ApexAgent.entitlements`, `Info.plist` URL schemes/usage descriptions, and `Package.swift` ↔ `project.yml`
/// weak-linked framework and rpath parity.
public enum BundleIntegrityVerifier {

    public static let requiredTrueEntitlements: [String] = [
        "com.apple.security.network.client",
        "com.apple.security.network.server",
        "com.apple.security.automation.apple-events",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.files.downloads.read-write",
        "com.apple.security.virtualization"
    ]

    public static let requiredFalseEntitlements: [String] = [
        "com.apple.security.app-sandbox",
        "com.apple.security.cs.allow-jit"
    ]

    public static let requiredWeakFrameworks: [String] = [
        "FoundationModels",
        "_FoundationModels_AppKit",
        "_FoundationModels_SwiftUI",
        "_Vision_FoundationModels",
        "_CoreSpotlight_FoundationModels"
    ]

    public static let requiredUsageDescriptionKeys: [String] = [
        "NSAppleEventsUsageDescription",
        "NSScreenCaptureDescription",
        "NSUserNotificationsUsageDescription",
        "NSDocumentsFolderUsageDescription",
        "NSDesktopFolderUsageDescription",
        "NSDownloadsFolderUsageDescription"
    ]

    /// Validates `ApexAgent.entitlements` plist data.
    public static func validateEntitlementsPlist(
        _ data: Data,
        filePath: String = "ApexAgent/ApexAgent.entitlements"
    ) -> [BundleIntegrityIssue] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return [
                BundleIntegrityIssue(
                    kind: .missingRequiredEntitlement,
                    file: filePath,
                    message: "Unable to parse entitlements property list."
                )
            ]
        }

        var issues: [BundleIntegrityIssue] = []

        for key in requiredTrueEntitlements {
            guard let val = plist[key] as? Bool else {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .missingRequiredEntitlement,
                        file: filePath,
                        message: "Missing required boolean entitlement '\(key)'."
                    )
                )
                continue
            }
            if !val {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .unexpectedEntitlementValue,
                        file: filePath,
                        message: "Entitlement '\(key)' must be true."
                    )
                )
            }
        }

        for key in requiredFalseEntitlements {
            guard let val = plist[key] as? Bool else {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .missingRequiredEntitlement,
                        file: filePath,
                        message: "Missing required boolean entitlement '\(key)'."
                    )
                )
                continue
            }
            if val {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .unexpectedEntitlementValue,
                        file: filePath,
                        message: "Hardened entitlement '\(key)' must be false."
                    )
                )
            }
        }

        let groups = (plist["com.apple.security.app-groups"] as? [String]) ?? []
        if !groups.contains("group.com.apexagent") {
            issues.append(
                BundleIntegrityIssue(
                    kind: .missingRequiredEntitlement,
                    file: filePath,
                    message: "Missing 'group.com.apexagent' in com.apple.security.app-groups."
                )
            )
        }

        return issues
    }

    /// Validates `Info.plist` data for required usage descriptions and `apexagent://` URL scheme registration.
    public static func validateInfoPlist(
        _ data: Data,
        filePath: String = "ApexAgent/Info.plist"
    ) -> [BundleIntegrityIssue] {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return [
                BundleIntegrityIssue(
                    kind: .missingInfoPlistKey,
                    file: filePath,
                    message: "Unable to parse Info.plist."
                )
            ]
        }

        var issues: [BundleIntegrityIssue] = []

        for key in requiredUsageDescriptionKeys {
            let desc = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if desc.isEmpty {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .missingInfoPlistKey,
                        file: filePath,
                        message: "Missing or empty privacy usage description key '\(key)'."
                    )
                )
            }
        }

        let urlTypes = (plist["CFBundleURLTypes"] as? [[String: Any]]) ?? []
        let registeredSchemes = urlTypes.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        if !registeredSchemes.contains(DeepLinkRouter.scheme) {
            issues.append(
                BundleIntegrityIssue(
                    kind: .missingURLSchemeRegistration,
                    file: filePath,
                    message: "Missing '\(DeepLinkRouter.scheme)' in CFBundleURLTypes.CFBundleURLSchemes."
                )
            )
        }

        return issues
    }

    /// Validates weak-linked framework parity, rpath, and ad-hoc signing configuration across `Package.swift` and `project.yml`.
    public static func validateBuildGraphParity(
        packageSwift: String,
        projectYML: String
    ) -> [BundleIntegrityIssue] {
        var issues: [BundleIntegrityIssue] = []

        for fw in requiredWeakFrameworks {
            if !packageSwift.contains("\"\(fw)\"") {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .missingWeakFrameworkFlag,
                        file: "Package.swift",
                        message: "Missing weak_framework linker flag for '\(fw)' in Package.swift."
                    )
                )
            }
            if !projectYML.contains("-weak_framework \(fw)") {
                issues.append(
                    BundleIntegrityIssue(
                        kind: .missingWeakFrameworkFlag,
                        file: "project.yml",
                        message: "Missing '-weak_framework \(fw)' in project.yml OTHER_LDFLAGS."
                    )
                )
            }
        }

        if !packageSwift.contains("@loader_path/../Frameworks") {
            issues.append(
                BundleIntegrityIssue(
                    kind: .missingRpathOrSigningConfig,
                    file: "Package.swift",
                    message: "Missing '@loader_path/../Frameworks' rpath linker setting in Package.swift."
                )
            )
        }

        if !projectYML.contains("CODE_SIGN_IDENTITY: \"-\"") {
            issues.append(
                BundleIntegrityIssue(
                    kind: .missingRpathOrSigningConfig,
                    file: "project.yml",
                    message: "Missing ad-hoc CODE_SIGN_IDENTITY: \"-\" in project.yml (required to embed virtualization entitlements)."
                )
            )
        }

        return issues
    }

    /// Runs all bundle integrity checks against `repoRoot`.
    public static func verifyRepositoryBundleIntegrity(atRepoRoot repoRoot: URL) -> BundleIntegrityReport {
        let entitlementsRel = "ApexAgent/ApexAgent.entitlements"
        let infoPlistRel = "ApexAgent/Info.plist"
        let packageRel = "Package.swift"
        let projectRel = "project.yml"

        var allIssues: [BundleIntegrityIssue] = []

        let entitlementsURL = repoRoot.appendingPathComponent(entitlementsRel)
        if let data = try? Data(contentsOf: entitlementsURL) {
            allIssues.append(contentsOf: validateEntitlementsPlist(data, filePath: entitlementsRel))
        } else {
            allIssues.append(
                BundleIntegrityIssue(
                    kind: .missingRequiredEntitlement,
                    file: entitlementsRel,
                    message: "Entitlements file not found at \(entitlementsRel)."
                )
            )
        }

        let infoURL = repoRoot.appendingPathComponent(infoPlistRel)
        if let data = try? Data(contentsOf: infoURL) {
            allIssues.append(contentsOf: validateInfoPlist(data, filePath: infoPlistRel))
        } else {
            allIssues.append(
                BundleIntegrityIssue(
                    kind: .missingInfoPlistKey,
                    file: infoPlistRel,
                    message: "Info.plist not found at \(infoPlistRel)."
                )
            )
        }

        let packageText = (try? String(contentsOf: repoRoot.appendingPathComponent(packageRel), encoding: .utf8)) ?? ""
        let projectText = (try? String(contentsOf: repoRoot.appendingPathComponent(projectRel), encoding: .utf8)) ?? ""
        allIssues.append(contentsOf: validateBuildGraphParity(packageSwift: packageText, projectYML: projectText))

        return BundleIntegrityReport(
            passed: allIssues.isEmpty,
            issues: allIssues,
            checkedFiles: [entitlementsRel, infoPlistRel, packageRel, projectRel]
        )
    }
}
