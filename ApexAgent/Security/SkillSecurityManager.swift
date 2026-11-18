import Foundation

// MARK: - Skill Security Manager (Issue #107)
//
// Central authority for skill supply-chain security:
// - Manages install-time scanning and manifest verification
// - Manages re-scan on update with automatic disablement
// - Enforces sandboxed-by-default execution
// - Manages the per-skill kill-switch with persistent state

public struct SkillKillRecord: Codable, Sendable, Equatable {
    public let name: String
    public let reason: String
    public let killedAt: Date

    public init(name: String, reason: String, killedAt: Date = Date()) {
        self.name = name
        self.reason = reason
        self.killedAt = killedAt
    }
}

public final class SkillSecurityManager: @unchecked Sendable {
    public static let shared = SkillSecurityManager()

    private static let userDefaultsKey = "apex.killedSkills"

    private let userDefaults: UserDefaults
    private let lock = NSLock()

    private var killedSkills: [String: SkillKillRecord] = [:]
    private var registeredManifests: [String: SkillPermissionManifest] = [:]
    private var scanFindingsHistory: [String: [SkillSecurityFinding]] = [:]

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        loadKilledSkills()
    }

    private func loadKilledSkills() {
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: SkillKillRecord].self, from: data) {
            self.killedSkills = decoded
        } else {
            self.killedSkills = [:]
        }
    }

    private func persistKilledSkills() {
        if let data = try? JSONEncoder().encode(killedSkills) {
            userDefaults.set(data, forKey: Self.userDefaultsKey)
        }
    }

    // MARK: - Per-Skill Kill-Switch

    /// Activates the kill-switch for a specific skill, disabling its execution immediately and persistently.
    public func killSkill(name: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }

        let record = SkillKillRecord(name: name, reason: reason, killedAt: Date())
        killedSkills[name] = record
        persistKilledSkills()
    }

    /// Reinstates a killed skill, removing it from the killed registry.
    public func reinstateSkill(name: String) {
        lock.lock()
        defer { lock.unlock() }

        killedSkills.removeValue(forKey: name)
        persistKilledSkills()
    }

    /// Checks whether a skill has been killed by the kill-switch or by an update failure.
    public func isKilled(name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return killedSkills[name] != nil
    }

    /// Returns the reason why a skill was killed, or nil if active.
    public func killReason(for name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return killedSkills[name]?.reason
    }

    /// Returns all currently killed skill records.
    public func allKilledSkills() -> [SkillKillRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(killedSkills.values).sorted(by: { $0.name < $1.name })
    }

    // MARK: - Manifest Registry & Findings

    /// Registers a validated permission manifest for a skill.
    public func registerManifest(_ manifest: SkillPermissionManifest) {
        lock.lock()
        defer { lock.unlock() }
        registeredManifests[manifest.name] = manifest
    }

    /// Unregisters a manifest for a removed skill.
    public func unregisterManifest(named name: String) {
        lock.lock()
        defer { lock.unlock() }
        registeredManifests.removeValue(forKey: name)
    }

    /// Returns the permission manifest for a registered skill, if known.
    public func permissionManifest(for name: String) -> SkillPermissionManifest? {
        lock.lock()
        defer { lock.unlock() }
        return registeredManifests[name]
    }

    /// Records scan findings for audit and inspection.
    public func recordScanFindings(skillName: String, findings: [SkillSecurityFinding]) {
        lock.lock()
        defer { lock.unlock() }
        scanFindingsHistory[skillName] = findings
    }

    /// Retrieves the most recent scan findings for a skill.
    public func latestFindings(for skillName: String) -> [SkillSecurityFinding]? {
        lock.lock()
        defer { lock.unlock() }
        return scanFindingsHistory[skillName]
    }

    // MARK: - Install-Time Verification

    /// Verifies manifest presence and scans script surface on install or registration.
    /// If the scan fails, install is blocked and findings are recorded.
    public func verifyInstall(
        manifest: SkillPermissionManifest?,
        scriptContent: String,
        workspacePath: String? = nil
    ) -> Result<SkillPermissionManifest, SkillSecurityError> {
        guard let manifest = manifest else {
            let finding = SkillSecurityFinding(
                ruleId: "MAN-001",
                category: .missingManifest,
                severity: .critical,
                message: "Registration refused: missing permission manifest"
            )
            recordScanFindings(skillName: "unknown", findings: [finding])
            return .failure(SkillSecurityError(findings: [finding]))
        }

        let scanResult = SkillSecurityScanner.scan(
            manifest: manifest,
            scriptContent: scriptContent,
            workspacePath: workspacePath
        )

        recordScanFindings(skillName: manifest.name, findings: scanResult.findings)

        if !scanResult.passed {
            return .failure(SkillSecurityError(findings: scanResult.findings))
        }

        registerManifest(manifest)
        return .success(manifest)
    }

    // MARK: - Re-Scan on Update

    /// Re-scans an updated skill. If the new code/config fails the security scan,
    /// the skill is automatically disabled/killed, findings are recorded, and execution is refused.
    public func verifyUpdate(
        name: String,
        updatedManifest: SkillPermissionManifest?,
        updatedScript: String,
        workspacePath: String? = nil
    ) -> Result<SkillPermissionManifest, SkillSecurityError> {
        guard let manifest = updatedManifest else {
            let finding = SkillSecurityFinding(
                ruleId: "MAN-001",
                category: .missingManifest,
                severity: .critical,
                message: "Update refused for '\(name)': missing permission manifest"
            )
            recordScanFindings(skillName: name, findings: [finding])
            killSkill(name: name, reason: "Security re-scan failed on update: missing manifest")
            return .failure(SkillSecurityError(findings: [finding]))
        }

        let scanResult = SkillSecurityScanner.scan(
            manifest: manifest,
            scriptContent: updatedScript,
            workspacePath: workspacePath
        )

        recordScanFindings(skillName: name, findings: scanResult.findings)

        if !scanResult.passed {
            let firstViolation = scanResult.findings.first(where: { $0.severity >= .high })?.message ?? "Dangerous pattern detected"
            killSkill(name: name, reason: "Security re-scan failed on update: \(firstViolation)")
            return .failure(SkillSecurityError(findings: scanResult.findings))
        }

        registerManifest(manifest)
        return .success(manifest)
    }

    // MARK: - Sandboxed Execution Validation

    /// Validates whether a skill is permitted to run, enforcing kill-switch status,
    /// manifest permission bounds, and integration with the approval path (#105).
    public func validateExecution(
        name: String,
        scriptPath: String,
        workspacePath: String? = nil
    ) throws {
        if isKilled(name: name) {
            let reason = killReason(for: name) ?? "Disabled by kill-switch"
            throw NSError(
                domain: "SkillSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' execution refused: disabled by kill-switch (\(reason))"]
            )
        }

        guard let manifest = permissionManifest(for: name) else {
            // Unregistered / manifest-less skill cannot execute
            throw NSError(
                domain: "SkillSecurity",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Tool '\(name)' execution refused: missing declared permission manifest"]
            )
        }

        // Sandboxed by default:
        // If the manifest declares elevated privileges (shell, network, or filesystem outside workspace),
        // verify that the action was approved via the existing approval path (ApprovalAllowlist).
        let perms = manifest.permissions
        let effectiveWorkspace = workspacePath ?? URL(fileURLWithPath: scriptPath).deletingLastPathComponent().path
        let outsidePaths = perms.filesystemPaths.filter { path in
            self.isPathOutsideWorkspace(path, workspace: effectiveWorkspace)
        }
        let requiresElevated = perms.allowShell || perms.allowNetwork || !outsidePaths.isEmpty
        if requiresElevated {
            let dir = effectiveWorkspace
            let isApproved = ApprovalAllowlist.shared.isAllowed(command: scriptPath, directory: dir)
                || ApprovalAllowlist.shared.isAllowed(command: name, directory: dir)

            if !isApproved {
                // Check if auto-review permits it or requires explicit approval
                let review = ApprovalAutoReview.review(
                    toolName: name,
                    command: scriptPath,
                    directory: dir,
                    workspacePath: workspacePath ?? dir,
                    allowlist: ApprovalAllowlist.shared
                )
                if !review.shouldAutoApprove {
                    throw NSError(
                        domain: "SkillSecurity",
                        code: 403,
                        userInfo: [NSLocalizedDescriptionKey: "Sandboxed skill '\(name)' execution denied: requires elevated permissions (\(describeElevatedPermissions(allowShell: perms.allowShell, allowNetwork: perms.allowNetwork, outsidePaths: outsidePaths))) and approval through the confirmation path."]
                    )
                }
            }
        }
    }

    private func isPathOutsideWorkspace(_ path: String, workspace: String) -> Bool {
        let standardPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardized.path
        let standardWorkspace = URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath).standardized.path
        if standardPath == standardWorkspace { return false }
        let prefix = standardWorkspace.hasSuffix("/") ? standardWorkspace : standardWorkspace + "/"
        return !standardPath.hasPrefix(prefix)
    }

    private func describeElevatedPermissions(allowShell: Bool, allowNetwork: Bool, outsidePaths: [String]) -> String {
        var parts: [String] = []
        if allowShell { parts.append("shell") }
        if allowNetwork { parts.append("network") }
        if !outsidePaths.isEmpty { parts.append("filesystem paths: \(outsidePaths.joined(separator: ", "))") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Testing Utilities

    /// Resets all in-memory and persistent security state for clean test isolation.
    public func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }

        killedSkills.removeAll()
        registeredManifests.removeAll()
        scanFindingsHistory.removeAll()
        userDefaults.removeObject(forKey: Self.userDefaultsKey)
    }
}
