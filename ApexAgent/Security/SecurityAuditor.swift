import Foundation
import AppKit

// MARK: - Security Sandbox Auditor
//
// Responsible for verifying filesystem boundaries, security-scoped sandbox bookmarks,
// symlink traversal prevention, and shell command security checks.

@MainActor
final class SecurityAuditor {
    static let shared = SecurityAuditor()

    init() {}

    func isFolderAccessRestricted(permissions: AppPermissions?) -> Bool {
        guard let permissions = permissions else {
            return true
        }
        return !permissions.musicFolderAllowed ||
               !permissions.desktopFolderAllowed ||
               !permissions.documentsFolderAllowed ||
               !permissions.downloadsFolderAllowed
    }

    func saveSandboxBookmark(for url: URL) {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        var bookmarks = UserDefaults.standard.dictionary(forKey: "apex.sandboxBookmarks") as? [String: Data] ?? [:]
        bookmarks[url.standardized.path] = bookmarkData
        UserDefaults.standard.set(bookmarks, forKey: "apex.sandboxBookmarks")
    }

    func accessSandboxBookmark(for path: String) -> URL? {
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: "apex.sandboxBookmarks") as? [String: Data] else {
            return nil
        }
        var currentPath = URL(fileURLWithPath: path).standardized.path
        while !currentPath.isEmpty && currentPath != "/" {
            if let data = bookmarks[currentPath] {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale),
                   url.startAccessingSecurityScopedResource() {
                    return url
                }
            }
            currentPath = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        }
        return nil
    }

    func verifyPathAllowed(_ path: String, workspacePath: String, permissions: AppPermissions?) throws(SecuritySandboxError) {
        let ws = (workspacePath.isEmpty || workspacePath == "." || workspacePath == "./")
            ? AgentOrchestrator.proactiveAuditWorkspacePath()
            : workspacePath
        let wsURL = URL(fileURLWithPath: ws)
        saveSandboxBookmark(for: wsURL)

        let effectivePerms = permissions ?? AppPermissions()

        var cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanPath = cleanPath.replacingOccurrences(of: "\\/", with: "/")
        let expanded = NSString(string: cleanPath).expandingTildeInPath
        let effectivePath: String
        if expanded.hasPrefix("/") {
            effectivePath = expanded
        } else if expanded.isEmpty || expanded == "." || expanded == "./" {
            effectivePath = ws
        } else {
            effectivePath = (ws as NSString).appendingPathComponent(expanded)
        }
        let rawStandardized = URL(fileURLWithPath: effectivePath).standardized.path
        let resolvedURL = URL(fileURLWithPath: effectivePath).resolvingSymlinksInPath()
        let standardized = resolvedURL.path

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let destinationOfSymlink: String?
        do {
            let rawDest = try fm.destinationOfSymbolicLink(atPath: path)
            destinationOfSymlink = NSString(string: rawDest).expandingTildeInPath
        } catch {
            destinationOfSymlink = nil
        }
        // Helper: does `p` land inside any forbidden home-relative directory?
        func isForbiddenHomeSubpath(_ p: String) -> Bool {
            let sensitiveNames = [".ssh", ".aws", ".gnupg", ".config", ".bash_history", ".zsh_history", ".netrc", ".zshrc", ".bashrc"]
            for name in sensitiveNames {
                let forbidden = (homeDir as NSString).appendingPathComponent(name)
                if p == forbidden || p.hasPrefix(forbidden + "/") { return true }
            }
            return false
        }

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")
        let sshPath = (homeDir as NSString).appendingPathComponent(".ssh")
        let awsPath = (homeDir as NSString).appendingPathComponent(".aws")
        let gnupgPath = (homeDir as NSString).appendingPathComponent(".gnupg")
        let configPath = (homeDir as NSString).appendingPathComponent(".config")
        let bashHistoryPath = (homeDir as NSString).appendingPathComponent(".bash_history")
        let zshHistoryPath = (homeDir as NSString).appendingPathComponent(".zsh_history")
        let netrcPath = (homeDir as NSString).appendingPathComponent(".netrc")

        let resolvedWorkspace = URL(fileURLWithPath: ws).resolvingSymlinksInPath().path
        let isInWorkspace = standardized == resolvedWorkspace || standardized.hasPrefix(resolvedWorkspace + "/")

        if !effectivePerms.desktopFolderAllowed && (standardized == desktopPath || standardized.hasPrefix(desktopPath + "/")) && !isInWorkspace {
            throw .desktopFolderRestricted
        }
        if !effectivePerms.documentsFolderAllowed && (standardized == documentsPath || standardized.hasPrefix(documentsPath + "/")) && !isInWorkspace {
            throw .documentsFolderRestricted
        }
        if !effectivePerms.downloadsFolderAllowed && (standardized == downloadsPath || standardized.hasPrefix(downloadsPath + "/")) && !isInWorkspace {
            throw .downloadsFolderRestricted
        }
        if !effectivePerms.musicFolderAllowed && (standardized == musicPath || standardized.hasPrefix(musicPath + "/")) && !isInWorkspace {
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
        if standardized == bashHistoryPath || standardized.hasPrefix(bashHistoryPath + "/") {
            throw .pathViolation(path)
        }
        if standardized == zshHistoryPath || standardized.hasPrefix(zshHistoryPath + "/") {
            throw .pathViolation(path)
        }
        if standardized == netrcPath || standardized.hasPrefix(netrcPath + "/") {
            throw .pathViolation(path)
        }

        // Forbidden-directory check on the raw symlink destination.
        if let dest = destinationOfSymlink, isForbiddenHomeSubpath(dest) {
            throw .symlinkTraversal(path)
        }

        // Host system root enforcement
        if standardized == "/" {
            throw .pathViolation(path)
        }

        let tempDir = NSTemporaryDirectory()
        let resolvedTemp = URL(fileURLWithPath: tempDir).resolvingSymlinksInPath().path
        let isSystemTmp = standardized == "/tmp" || standardized.hasPrefix("/tmp/")
            || standardized == "/private/tmp" || standardized.hasPrefix("/private/tmp/")
        let isInTemp = standardized == resolvedTemp || standardized.hasPrefix(resolvedTemp + "/") || isSystemTmp

        let resolvedSkills = ApexAgentStoragePaths.skills.resolvingSymlinksInPath().path
        let resolvedDotApex = ApexAgentStoragePaths.apex.resolvingSymlinksInPath().path
        let apexDir = (homeDir as NSString).appendingPathComponent("apex")
        let resolvedApex = URL(fileURLWithPath: apexDir).resolvingSymlinksInPath().path
        let userTmpDir = (homeDir as NSString).appendingPathComponent("tmp")
        let resolvedUserTmp = URL(fileURLWithPath: userTmpDir).resolvingSymlinksInPath().path

        let isInSkills = standardized == resolvedSkills || standardized.hasPrefix(resolvedSkills + "/")
            || standardized == resolvedDotApex || standardized.hasPrefix(resolvedDotApex + "/")
            || standardized == resolvedApex || standardized.hasPrefix(resolvedApex + "/")
            || standardized == resolvedUserTmp || standardized.hasPrefix(resolvedUserTmp + "/")

        let forbiddenSystemPrefixes = [
            "/System", "/Library", "/etc", "/private/etc", "/usr", "/bin", "/sbin", "/var", "/private/var", "/dev", "/Volumes"
        ]

        // 1. Symlink Traversal Detection:
        let isSymlink = (destinationOfSymlink != nil) || (rawStandardized != standardized)
        if isSymlink {
            for forbidden in forbiddenSystemPrefixes {
                if standardized == forbidden || standardized.hasPrefix(forbidden + "/") {
                    throw .symlinkTraversal(path)
                }
            }
            if let dest = destinationOfSymlink {
                for forbidden in forbiddenSystemPrefixes {
                    if dest == forbidden || dest.hasPrefix(forbidden + "/") {
                        throw .symlinkTraversal(path)
                    }
                }
            }
            let rawInWorkspace = rawStandardized == workspacePath || rawStandardized.hasPrefix(workspacePath + "/") || rawStandardized == resolvedWorkspace || rawStandardized.hasPrefix(resolvedWorkspace + "/")
            if rawInWorkspace && !isInWorkspace {
                throw .symlinkTraversal(path)
            }
        }

        // 2. Direct system directory access
        for forbidden in forbiddenSystemPrefixes {
            if standardized == forbidden || standardized.hasPrefix(forbidden + "/") {
                if !isInTemp {
                    throw .pathViolation(path)
                }
            }
        }

        if accessSandboxBookmark(for: standardized) != nil {
            return
        }

        if isInWorkspace || isInTemp || isInSkills {
            return
        }

        throw .pathViolation(path)
    }

    func isPathAllowed(_ path: String, workspacePath: String, permissions: AppPermissions?) -> Bool {
        do {
            try verifyPathAllowed(path, workspacePath: workspacePath, permissions: permissions)
            return true
        } catch {
            return false
        }
    }

    func isCommandOrScriptAllowed(_ input: String, permissions: AppPermissions?, isContainerSandboxed: Bool = false) -> Bool {
        if isContainerSandboxed {
            return true
        }

        guard let permissions = permissions else {
            return false
        }

        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser.standardized.path

        let desktopPath = (homeDir as NSString).appendingPathComponent("Desktop")
        let documentsPath = (homeDir as NSString).appendingPathComponent("Documents")
        let downloadsPath = (homeDir as NSString).appendingPathComponent("Downloads")
        let musicPath = (homeDir as NSString).appendingPathComponent("Music")

        let desktopAllowed = permissions.desktopFolderAllowed
        let documentsAllowed = permissions.documentsFolderAllowed
        let downloadsAllowed = permissions.downloadsFolderAllowed
        let musicAllowed = permissions.musicFolderAllowed

        if !desktopAllowed && (input.contains(desktopPath) || input.contains("~/Desktop")) {
            return false
        }
        if !documentsAllowed && (input.contains(documentsPath) || input.contains("~/Documents")) {
            return false
        }
        if !downloadsAllowed && (input.contains(downloadsPath) || input.contains("~/Downloads")) {
            return false
        }
        if !musicAllowed && (input.contains(musicPath) || input.contains("~/Music")) {
            return false
        }

        return true
    }

    /// Redacts sensitive information such as API keys, bearer tokens, passwords, and private keys.
    nonisolated public static func redactSensitiveData(in text: String) -> String {
        var sanitized = text

        // Redact standard API key patterns: sk-..., AIza...
        let patterns: [(regex: String, replacement: String)] = [
            (#"sk-[a-zA-Z0-9_-]{20,}"#, "[REDACTED_API_KEY]"),
            (#"AIza[0-9A-Za-z_-]{20,}"#, "[REDACTED_GEMINI_KEY]"),
            (#"Bearer\s+[a-zA-Z0-9._-]{10,}"#, "Bearer [REDACTED_TOKEN]"),
            (#""(password|token|secret|apiKey|api_key)"\s*:\s*"[^"]+""#, #""$1": "[REDACTED]""#),
            (#"-----BEGIN [A-Z ]+ PRIVATE KEY-----[\s\S]*?-----END [A-Z ]+ PRIVATE KEY-----"#, "[REDACTED_PRIVATE_KEY]")
        ]

        for (regexStr, replacement) in patterns {
            if let regex = try? NSRegularExpression(pattern: regexStr, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: sanitized.utf16.count)
                sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: replacement)
            }
        }

        return sanitized
    }

    // MARK: - Security Policy Markdown Export

    nonisolated public static func exportSecurityPolicyMarkdown() -> String {
        var md = "### 🛡️ ApexAgent Security & Host Sandbox Enforcement Policy\n\n"
        md += "| Security Domain | Protected Scope | Enforcement Mechanism |\n"
        md += "|---|---|---|\n"
        md += "| Credential Vault | `~/.ssh`, `~/.aws`, `~/.gnupg` | Hard Deny (Path Violation) |\n"
        md += "| Shell & Secrets | `~/.bash_history`, `~/.zsh_history`, `~/.netrc` | Hard Deny (Path Violation) |\n"
        md += "| User Config | `~/.config` | Hard Deny (Path Violation) |\n"
        md += "| OS System Trees | `/System`, `/Library`, `/etc`, `/usr`, `/bin` | Hard Deny (System Restriction) |\n"
        md += "| Root Filesystem | `/` | Hard Deny (System Restriction) |\n"
        md += "| User Media Dirs | `~/Desktop`, `~/Documents`, `~/Downloads` | Permission-gated via AppPermissions |\n"
        md += "| Symlink Traversal | Symlinks resolving outside workspace/tmp | Hard Deny (Symlink Traversal Trap) |\n"
        md += "| Data Leak Prevention | Bearer tokens, OpenAI keys, Gemini keys, PEM | Dynamic Regular Expression Sanitization |\n"
        return md
    }

}