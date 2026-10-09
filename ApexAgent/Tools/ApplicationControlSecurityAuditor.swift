import Foundation
import Darwin

// MARK: - Application Control Tool PID & Bundle Security Gate (Batch 88)

/// Security classification for application targets controlled by GUI automation.
public struct AppTargetProfile: Sendable, Codable, Equatable {
    public let appName: String
    public let bundleId: String?
    public let isAllowedByDefault: Bool
    public let isProtectedSystemApp: Bool

    public init(
        appName: String,
        bundleId: String? = nil,
        isAllowedByDefault: Bool = true,
        isProtectedSystemApp: Bool = false
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.isAllowedByDefault = isAllowedByDefault
        self.isProtectedSystemApp = isProtectedSystemApp
    }
}

/// Violation detected when verifying application automation requests.
public struct AppControlSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Security audit report for an application automation request.
public struct AppControlSecurityReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let sanitizedParameter: String?
    public let targetAppName: String
    public let violations: [AppControlSecurityViolation]

    public init(
        passed: Bool,
        score: Double,
        sanitizedParameter: String?,
        targetAppName: String,
        violations: [AppControlSecurityViolation]
    ) {
        self.passed = passed
        self.score = score
        self.sanitizedParameter = sanitizedParameter
        self.targetAppName = targetAppName
        self.violations = violations
    }
}

/// Security gate and parameter sanitizer for macOS application automation.
public enum ApplicationControlSecurityAuditor {

    // MARK: - Protected System Apps & Allowlist

    public static let protectedBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.apple.keychainaccess",
        "com.apple.ActivityMonitor",
        "com.apple.installer",
        "com.apple.Console",
        "com.apple.SecurityAgent",
        "com.apple.systempreferences" // Raw root preferences without pane constraints
    ]

    public static let standardAllowedApps: Set<String> = [
        "safari",
        "chrome",
        "google chrome",
        "finder",
        "system settings"
    ]

    public static let standardAllowedActions: Set<String> = [
        "open_url",
        "get_active_tab",
        "open_folder",
        "get_selected",
        "open_preference_pane"
    ]

    // MARK: - Parameter Sanitization

    /// Sanitizes parameter inputs to prevent AppleScript injection attacks.
    public static func sanitizeAppleScriptParameter(_ raw: String) -> String {
        var sanitized = raw
        // Escape backslashes first
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "\\\\")
        // Escape double quotes
        sanitized = sanitized.replacingOccurrences(of: "\"", with: "\\\"")
        // Strip null bytes and control characters
        sanitized = sanitized.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return scalar >= 32 || scalar == 9 || scalar == 10 || scalar == 13
        }
        return sanitized
    }

    /// Checks if a string contains dangerous AppleScript injection primitives.
    public static func detectAppleScriptInjection(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        let patterns = [
            "do shell script",
            "tell application",
            "system events",
            "keystroke",
            "key code",
            "posix file",
            "quoted form of"
        ]
        return patterns.contains { lower.contains($0) }
    }

    // MARK: - PID Liveness

    /// Verifies whether a given process ID corresponds to an active, living process.
    public static func isProcessAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // kill(pid, 0) performs error checking without sending a signal
        if kill(pid, 0) == 0 {
            return true
        }
        // If error is EPERM, the process exists but is owned by another user/root
        return errno == EPERM
    }

    // MARK: - Action & Target Audit

    /// Audits an application control command for security violations and injection attempts.
    public static func auditControlRequest(
        appName: String,
        action: String,
        parameter: String?,
        bundleId: String? = nil,
        customAllowedApps: Set<String>? = nil
    ) -> AppControlSecurityReport {
        var violations: [AppControlSecurityViolation] = []
        let cleanAppName = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. App name empty check
        if cleanAppName.isEmpty {
            violations.append(AppControlSecurityViolation(
                code: "EMPTY_APP_NAME",
                message: "Target application name cannot be empty."
            ))
        }

        // 2. Action empty check
        if cleanAction.isEmpty {
            violations.append(AppControlSecurityViolation(
                code: "EMPTY_ACTION",
                message: "Target action cannot be empty."
            ))
        }

        // 3. Protected system app check
        if let bId = bundleId, protectedBundleIds.contains(bId) {
            violations.append(AppControlSecurityViolation(
                code: "PROTECTED_SYSTEM_APP_BLOCKED",
                message: "Target application bundle ID '\(bId)' is a protected system application."
            ))
        }

        // 4. Target app allowlist check
        let allowedSet = customAllowedApps ?? standardAllowedApps
        if !cleanAppName.isEmpty && !allowedSet.contains(cleanAppName) {
            violations.append(AppControlSecurityViolation(
                code: "UNAUTHORIZED_TARGET_APP",
                message: "Target application '\(appName)' is not in the allowed automation set."
            ))
        }

        // 5. Action allowlist check
        if !cleanAction.isEmpty && !standardAllowedActions.contains(cleanAction) {
            violations.append(AppControlSecurityViolation(
                code: "UNAUTHORIZED_ACTION",
                message: "Action '\(action)' is not an approved GUI automation action."
            ))
        }

        // 6. Parameter audit & injection check
        var sanitizedParam: String? = nil
        if let rawParam = parameter {
            if detectAppleScriptInjection(rawParam) {
                violations.append(AppControlSecurityViolation(
                    code: "APPLESCRIPT_INJECTION_DETECTED",
                    message: "Parameter contains dangerous AppleScript command keywords."
                ))
            }
            sanitizedParam = sanitizeAppleScriptParameter(rawParam)
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty
        let score = passed ? (violations.isEmpty ? 100.0 : 75.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return AppControlSecurityReport(
            passed: passed,
            score: score,
            sanitizedParameter: sanitizedParam,
            targetAppName: appName,
            violations: violations
        )
    }
}
