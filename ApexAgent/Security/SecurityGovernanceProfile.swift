import Foundation

// MARK: - Security Governance Profile (M3: Containerization & Sandboxctl Enhancements)

public enum ExecutionScope: String, Sendable, Codable, CaseIterable {
    case host = "host"
    case container = "container"
}

public enum GovernanceProfileKind: String, Sendable, Codable, CaseIterable {
    case hostStrict = "host-strict"
    case hostDeveloper = "host-developer"
    case containerStandard = "container-standard"
    case containerStrict = "container-strict"
}

public struct SecurityGovernanceProfile: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let scope: ExecutionScope
    public let isolationLevel: ContainerIsolationLevel
    public let allowNetwork: Bool
    public let allowHostFilesystemMount: Bool
    public let autoApprovePackageInstall: Bool
    public let blockDestructiveHostCommands: Bool
    public let blockSensitiveFileAccess: Bool
    public let restrictedHostPaths: [String]
    public let customAllowedPaths: [String]

    public init(
        id: String,
        name: String,
        scope: ExecutionScope,
        isolationLevel: ContainerIsolationLevel,
        allowNetwork: Bool,
        allowHostFilesystemMount: Bool,
        autoApprovePackageInstall: Bool,
        blockDestructiveHostCommands: Bool,
        blockSensitiveFileAccess: Bool,
        restrictedHostPaths: [String] = [],
        customAllowedPaths: [String] = []
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.isolationLevel = isolationLevel
        self.allowNetwork = allowNetwork
        self.allowHostFilesystemMount = allowHostFilesystemMount
        self.autoApprovePackageInstall = autoApprovePackageInstall
        self.blockDestructiveHostCommands = blockDestructiveHostCommands
        self.blockSensitiveFileAccess = blockSensitiveFileAccess
        self.restrictedHostPaths = restrictedHostPaths
        self.customAllowedPaths = customAllowedPaths
    }

    // MARK: - Built-in Presets

    public static let hostStrict = SecurityGovernanceProfile(
        id: "host-strict",
        name: "Host Strict Security",
        scope: .host,
        isolationLevel: .strict,
        allowNetwork: false,
        allowHostFilesystemMount: false,
        autoApprovePackageInstall: false,
        blockDestructiveHostCommands: true,
        blockSensitiveFileAccess: true,
        restrictedHostPaths: [
            "~/Desktop",
            "~/Documents",
            "~/Downloads",
            "~/Music",
            "/",
            "/System",
            "/Library",
            "/etc",
            "/var",
            "/usr",
            "/bin",
            "/sbin",
            "/private",
            "~/.ssh",
            "~/.aws",
            "~/.gnupg"
        ]
    )

    public static let hostDeveloper = SecurityGovernanceProfile(
        id: "host-developer",
        name: "Host Developer Security",
        scope: .host,
        isolationLevel: .standard,
        allowNetwork: true,
        allowHostFilesystemMount: true,
        autoApprovePackageInstall: false,
        blockDestructiveHostCommands: true,
        blockSensitiveFileAccess: true,
        restrictedHostPaths: [
            "~/Desktop",
            "~/Documents",
            "~/Downloads",
            "~/Music",
            "/",
            "/System",
            "/Library",
            "/etc",
            "/var",
            "/usr",
            "/bin",
            "/sbin",
            "/private",
            "~/.ssh",
            "~/.aws",
            "~/.gnupg"
        ]
    )

    public static let containerStandard = SecurityGovernanceProfile(
        id: "container-standard",
        name: "Container Standard Sandbox",
        scope: .container,
        isolationLevel: .standard,
        allowNetwork: true,
        allowHostFilesystemMount: true,
        autoApprovePackageInstall: true,
        blockDestructiveHostCommands: true,
        blockSensitiveFileAccess: false,
        restrictedHostPaths: [
            "/",
            "/System",
            "/Library",
            "/etc",
            "/var",
            "/private"
        ]
    )

    public static let containerStrict = SecurityGovernanceProfile(
        id: "container-strict",
        name: "Container Strict Sandbox",
        scope: .container,
        isolationLevel: .strict,
        allowNetwork: false,
        allowHostFilesystemMount: false,
        autoApprovePackageInstall: true,
        blockDestructiveHostCommands: true,
        blockSensitiveFileAccess: true,
        restrictedHostPaths: [
            "/",
            "/System",
            "/Library",
            "/etc",
            "/var",
            "/private",
            "~/.ssh",
            "~/.aws",
            "~/.gnupg"
        ]
    )

    public static func profile(for kind: GovernanceProfileKind) -> SecurityGovernanceProfile {
        switch kind {
        case .hostStrict: return .hostStrict
        case .hostDeveloper: return .hostDeveloper
        case .containerStandard: return .containerStandard
        case .containerStrict: return .containerStrict
        }
    }

    // MARK: - Validation

    public func validateFilesystemAccess(path: String, isContainerSandboxed: Bool = false) throws(SecuritySandboxError) {
        let expanded = NSString(string: path).expandingTildeInPath
        let resolvedURL = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        let standardized = resolvedURL.path

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path

        // Tilde-traversal guard: if the original path started inside the home
        // directory but the resolved path landed outside it, the caller is
        // using `~/.../..` to escape — reject unconditionally.
        if expanded.hasPrefix("~/") || expanded.hasPrefix(homeDir + "/") || expanded == homeDir {
            if !standardized.hasPrefix(homeDir + "/") && standardized != homeDir {
                throw .pathViolation(path)
            }
        }

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")
        let sshPath = (homeDir as NSString).appendingPathComponent(".ssh")
        let awsPath = (homeDir as NSString).appendingPathComponent(".aws")
        let gnupgPath = (homeDir as NSString).appendingPathComponent(".gnupg")
        let configPath = (homeDir as NSString).appendingPathComponent(".config")

        // In strict mode or host mode, check restricted paths
        if scope == .host || !isContainerSandboxed {
            if standardized == desktopPath || standardized.hasPrefix(desktopPath + "/") {
                throw .desktopFolderRestricted
            }
            if standardized == documentsPath || standardized.hasPrefix(documentsPath + "/") {
                throw .documentsFolderRestricted
            }
            if standardized == downloadsPath || standardized.hasPrefix(downloadsPath + "/") {
                throw .downloadsFolderRestricted
            }
            if standardized == musicPath || standardized.hasPrefix(musicPath + "/") {
                throw .musicFolderRestricted
            }
            if standardized == sshPath || standardized.hasPrefix(sshPath + "/") {
                throw .pathViolation(path)
            }
            if standardized == awsPath || standardized.hasPrefix(awsPath + "/") {
                throw .pathViolation(path)
            }
            if standardized == gnupgPath || standardized.hasPrefix(gnupgPath + "/") {
                throw .pathViolation(path)
            }
            if standardized == configPath || standardized.hasPrefix(configPath + "/") {
                throw .pathViolation(path)
            }
        }

        // Check system root restrictions
        let systemRoots = ["/System", "/Library", "/etc", "/var", "/usr", "/bin", "/sbin", "/private"]
        if standardized == "/" {
            throw .pathViolation(path)
        }
        for sys in systemRoots {
            if standardized == sys || standardized.hasPrefix(sys + "/") {
                throw .pathViolation(path)
            }
        }

        // Check configured restricted paths
        for restricted in restrictedHostPaths {
            let expRestricted = NSString(string: restricted).expandingTildeInPath
            let stdRestricted = URL(fileURLWithPath: expRestricted).standardized.path
            if standardized == stdRestricted || standardized.hasPrefix(stdRestricted + "/") {
                throw .pathViolation(path)
            }
        }
    }

    public func validateCommand(command: String, isContainerSandboxed: Bool = false) -> Bool {
        if isContainerSandboxed && scope == .container && isolationLevel != .strict {
            // Standard container sandbox allows most guest commands, guarding
            // only destructive host disk actions. The full destructive list
            // applies here too — not just diskutil/mkfs.
            if blockDestructiveHostCommands && Self.destructiveCommandPatterns.contains(where: { command.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            return true
        }

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        let forbiddenPhrases = [
            "~/Desktop", "~/Documents", "~/Downloads", "~/Music",
            desktopPath, documentsPath, downloadsPath, musicPath,
            "~/.ssh", "~/.aws", "~/.gnupg"
        ]

        if blockSensitiveFileAccess {
            for phrase in forbiddenPhrases {
                if command.contains(phrase) {
                    // Network profiles may invoke `ssh -i ~/.ssh/key …`: the
                    // key is being *used* for a connection, not exfiltrated,
                    // and the profile explicitly permits network access.
                    let isSSHKeyUsage = allowNetwork
                        && command.lowercased().hasPrefix("ssh")
                        && phrase == "~/.ssh"
                    if isSSHKeyUsage { continue }
                    return false
                }
            }
        }

        if !allowNetwork {
            let networkKeywords = ["curl", "wget", "nc", "ssh", "ping", "telnet", "git clone", "git push", "git pull"]
            for kw in networkKeywords {
                if command.localizedCaseInsensitiveContains(kw) {
                    return false
                }
            }
        }

        if blockDestructiveHostCommands {
            if Self.destructiveCommandPatterns.contains(where: { command.localizedCaseInsensitiveContains($0) }) {
                return false
            }
        }

        return true
    }

    /// Command fragments that are always considered destructive to the host
    /// and blocked in every governance profile (host and container alike).
    private static let destructiveCommandPatterns = [
        "rm -rf /",
        "diskutil erase",
        "mkfs",
        "dd of=/dev/"
    ]
}
