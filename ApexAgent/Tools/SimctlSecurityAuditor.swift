import Foundation

// MARK: - Simctl Tool Simulator State Lifecycle Gate (Batch 93)

/// Lifecycle states of iOS/watchOS/tvOS simulators.
public enum SimulatorLifecycleState: String, Sendable, Codable, Equatable, CaseIterable {
    case shutdown = "Shutdown"
    case booting = "Booting"
    case booted = "Booted"
    case shuttingDown = "Shutting Down"
    case unknown = "Unknown"
}

/// Approved actions for xcrun simctl tool.
public enum SimctlAction: String, Sendable, Codable, Equatable, CaseIterable {
    case list
    case boot
    case shutdown
    case install
    case launch
    case screenshot
    case openurl
}

/// Violation detected during simctl command security and lifecycle audit.
public struct SimctlSecurityViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Audit report produced by verifying simctl invocation arguments and lifecycle states.
public struct SimctlSecurityReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let sanitizedArgs: [String]?
    public let violations: [SimctlSecurityViolation]

    public init(
        passed: Bool,
        score: Double,
        sanitizedArgs: [String]?,
        violations: [SimctlSecurityViolation]
    ) {
        self.passed = passed
        self.score = score
        self.sanitizedArgs = sanitizedArgs
        self.violations = violations
    }
}

/// Security auditor and lifecycle state validator for `xcrun simctl` actions.
public enum SimctlSecurityAuditor {

    // Valid state transitions
    private static let validTransitions: [SimulatorLifecycleState: Set<SimulatorLifecycleState>] = [
        .shutdown: [.booting, .booted],
        .booting: [.booted, .shutdown],
        .booted: [.shuttingDown, .shutdown],
        .shuttingDown: [.shutdown],
        .unknown: [.shutdown, .booted]
    ]

    // MARK: - Validation Utilities

    /// Validates UDID syntax (either RFC 4122 8-4-4-4-12 hex UUID or special alias 'booted').
    public static func validateUDID(_ udid: String) -> Bool {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "booted" { return true }
        let uuidRegex = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        return trimmed.range(of: uuidRegex, options: .regularExpression) != nil
    }

    /// Validates application bundle ID syntax (e.g. `com.example.MyApp`).
    public static func validateBundleId(_ bundleId: String) -> Bool {
        let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let bundleRegex = #"^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)+$"#
        return trimmed.range(of: bundleRegex, options: .regularExpression) != nil
    }

    /// Validates whether a path points to an iOS `.app` application bundle.
    public static func validateAppBundlePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasSuffix(".app") || trimmed.hasSuffix(".app/")
    }

    /// Validates state transition between simulator states.
    public static func validateStateTransition(
        from current: SimulatorLifecycleState,
        to next: SimulatorLifecycleState
    ) -> Bool {
        if current == next { return true }
        return validTransitions[current]?.contains(next) ?? false
    }

    // MARK: - Action Audit

    /// Audits a simctl action and its arguments against concurrency quotas, input syntax, and lifecycle rules.
    public static func auditSimctlRequest(
        action: String,
        deviceId: String? = nil,
        appPath: String? = nil,
        bundleId: String? = nil,
        url: String? = nil,
        savePath: String? = nil,
        currentlyBootedCount: Int = 0,
        maxBootedCount: Int = 2
    ) -> SimctlSecurityReport {
        var violations: [SimctlSecurityViolation] = []
        let cleanAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let simctlAction = SimctlAction(rawValue: cleanAction) else {
            violations.append(SimctlSecurityViolation(
                code: "UNKNOWN_SIMCTL_ACTION",
                message: "Unrecognized simctl action '\(action)'. Approved actions: \(SimctlAction.allCases.map(\.rawValue).joined(separator: ", "))."
            ))
            return SimctlSecurityReport(passed: false, score: 0.0, sanitizedArgs: nil, violations: violations)
        }

        var constructedArgs: [String] = ["simctl", simctlAction.rawValue]

        switch simctlAction {
        case .list:
            constructedArgs.append(contentsOf: ["devices", "-j"])

        case .boot:
            guard let devId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !devId.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_DEVICE_ID",
                    message: "Device ID required for boot action."
                ))
                break
            }
            if !validateUDID(devId) {
                violations.append(SimctlSecurityViolation(
                    code: "INVALID_DEVICE_UDID",
                    message: "Device ID '\(devId)' is not a valid UUID format."
                ))
            }
            if currentlyBootedCount >= maxBootedCount {
                violations.append(SimctlSecurityViolation(
                    code: "CONCURRENT_BOOT_LIMIT_EXCEEDED",
                    message: "Currently booted \(currentlyBootedCount) simulators exceeds maximum limit of \(maxBootedCount)."
                ))
            }
            constructedArgs.append(devId)

        case .shutdown:
            guard let devId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !devId.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_DEVICE_ID",
                    message: "Device ID required for shutdown action."
                ))
                break
            }
            if !validateUDID(devId) {
                violations.append(SimctlSecurityViolation(
                    code: "INVALID_DEVICE_UDID",
                    message: "Device ID '\(devId)' is not a valid UUID format."
                ))
            }
            constructedArgs.append(devId)

        case .install:
            guard let devId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !devId.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_DEVICE_ID",
                    message: "Device ID required for install action."
                ))
                break
            }
            guard let path = appPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_APP_PATH",
                    message: "App path required for install action."
                ))
                break
            }
            if !validateAppBundlePath(path) {
                violations.append(SimctlSecurityViolation(
                    code: "INVALID_APP_BUNDLE_EXTENSION",
                    message: "App path '\(path)' must have a .app extension."
                ))
            }
            constructedArgs.append(contentsOf: [devId, path])

        case .launch:
            guard let devId = deviceId?.trimmingCharacters(in: .whitespacesAndNewlines), !devId.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_DEVICE_ID",
                    message: "Device ID required for launch action."
                ))
                break
            }
            guard let bId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bId.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_BUNDLE_ID",
                    message: "Bundle ID required for launch action."
                ))
                break
            }
            if !validateBundleId(bId) {
                violations.append(SimctlSecurityViolation(
                    code: "INVALID_BUNDLE_ID_SYNTAX",
                    message: "Bundle ID '\(bId)' must follow reverse-DNS convention."
                ))
            }
            constructedArgs.append(contentsOf: [devId, bId])

        case .screenshot:
            let devId = deviceId ?? "booted"
            guard let sPath = savePath?.trimmingCharacters(in: .whitespacesAndNewlines), !sPath.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_SAVE_PATH",
                    message: "Save path required for screenshot action."
                ))
                break
            }
            if !sPath.hasSuffix(".png") {
                violations.append(SimctlSecurityViolation(
                    code: "INVALID_SCREENSHOT_EXTENSION",
                    message: "Screenshot save path must end with .png."
                ))
            }
            constructedArgs.append(contentsOf: ["io", devId, "screenshot", sPath])

        case .openurl:
            let devId = deviceId ?? "booted"
            guard let u = url?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty else {
                violations.append(SimctlSecurityViolation(
                    code: "MISSING_URL",
                    message: "URL required for openurl action."
                ))
                break
            }
            constructedArgs.append(contentsOf: [devId, u])
        }

        let fatalViolations = violations.filter(\.isFatal)
        let passed = fatalViolations.isEmpty

        let score = passed ? (violations.isEmpty ? 100.0 : 80.0) : max(0.0, 100.0 - Double(fatalViolations.count) * 25.0)

        return SimctlSecurityReport(
            passed: passed,
            score: score,
            sanitizedArgs: passed ? constructedArgs : nil,
            violations: violations
        )
    }
}
