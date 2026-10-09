import Foundation
import Darwin
import Testing
@testable import ApexAgentCore

@Suite("Batch 88 — Application Control Tool PID & Bundle Security Gate Tests")
struct ApplicationControlSecurityAuditorTests {

    @Test("Valid Safari open_url request passes security audit with 100% score")
    func validSafariRequestPasses() {
        let report = ApplicationControlSecurityAuditor.auditControlRequest(
            appName: "Safari",
            action: "open_url",
            parameter: "https://apple.com"
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.targetAppName == "Safari")
        #expect(report.sanitizedParameter == "https://apple.com")
        #expect(report.violations.isEmpty)
    }

    @Test("Parameter sanitizer properly escapes backslashes and double quotes")
    func parameterSanitizationEscapesSpecialChars() {
        let raw = "Path with \"quotes\" and \\backslashes\\"
        let sanitized = ApplicationControlSecurityAuditor.sanitizeAppleScriptParameter(raw)

        #expect(sanitized == "Path with \\\"quotes\\\" and \\\\backslashes\\\\")
    }

    @Test("AppleScript injection attempt triggers APPLESCRIPT_INJECTION_DETECTED violation")
    func appleScriptInjectionBlocked() {
        let injectionPayload = "https://example.com\" & do shell script \"whoami\" & \""
        let report = ApplicationControlSecurityAuditor.auditControlRequest(
            appName: "Safari",
            action: "open_url",
            parameter: injectionPayload
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "APPLESCRIPT_INJECTION_DETECTED" })
    }

    @Test("Protected system application bundle ID is blocked")
    func protectedSystemAppBlocked() {
        let report = ApplicationControlSecurityAuditor.auditControlRequest(
            appName: "Terminal",
            action: "open_url",
            parameter: nil,
            bundleId: "com.apple.Terminal"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "PROTECTED_SYSTEM_APP_BLOCKED" })
    }

    @Test("Unauthorized application name is rejected")
    func unauthorizedAppRejected() {
        let report = ApplicationControlSecurityAuditor.auditControlRequest(
            appName: "RandomUnknownApp",
            action: "open_url",
            parameter: "https://test.com"
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "UNAUTHORIZED_TARGET_APP" })
    }

    @Test("Real process PID liveness detection validates self process and rejects invalid PIDs")
    func pidLivenessValidation() {
        let myPID = getpid()
        #expect(ApplicationControlSecurityAuditor.isProcessAlive(pid: myPID))

        // Negative PID and PID 0 are rejected
        #expect(!ApplicationControlSecurityAuditor.isProcessAlive(pid: -1))
        #expect(!ApplicationControlSecurityAuditor.isProcessAlive(pid: 0))

        // Arbitrary out-of-range PID
        #expect(!ApplicationControlSecurityAuditor.isProcessAlive(pid: 99999999))
    }

    @Test("Empty app name and empty action produce fatal violations")
    func emptyInputsFail() {
        let report = ApplicationControlSecurityAuditor.auditControlRequest(
            appName: "",
            action: "",
            parameter: nil
        )

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "EMPTY_APP_NAME" })
        #expect(report.violations.contains { $0.code == "EMPTY_ACTION" })
    }
}
