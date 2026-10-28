import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 94 — AppleScript OSA AST & Script Execution Gate Tests")
struct AppleScriptSecurityAuditorTests {

    @Test("Valid benign AppleScript passes security audit with 100% score and safe risk level")
    func validScriptPasses() {
        let script = "tell application \"Finder\" to get name of startup disk"
        let report = AppleScriptSecurityAuditor.auditScript(script)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.riskLevel == .safe)
        #expect(report.sanitizedScript == script)
        #expect(report.violations.isEmpty)

        // Verify real compile syntax
        let (isCompiled, err) = AppleScriptSecurityAuditor.verifyCompilationSyntax(script)
        #expect(isCompiled)
        #expect(err == nil)
    }

    @Test("Script attempting administrator privileges is prohibited")
    func adminPrivilegesProhibited() {
        let script = "do shell script \"whoami\" with administrator privileges"
        let report = AppleScriptSecurityAuditor.auditScript(script)

        #expect(!report.passed)
        #expect(report.riskLevel == .prohibited)
        #expect(report.violations.contains { $0.code == "ADMINISTRATOR_PRIVILEGES_PROHIBITED" })
    }

    @Test("Do shell script command is prohibited by default")
    func doShellScriptProhibited() {
        let script = "do shell script \"echo hello\""
        let report = AppleScriptSecurityAuditor.auditScript(script)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "DO_SHELL_SCRIPT_PROHIBITED" })
    }

    @Test("Synthetic keystroke injection via System Events is prohibited")
    func keystrokeInjectionProhibited() {
        let script = "tell application \"System Events\" to keystroke \"secret_text\""
        let report = AppleScriptSecurityAuditor.auditScript(script)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "SYNTHETIC_KEYSTROKE_PROHIBITED" })
    }

    @Test("Targeting blocked terminal applications is prohibited")
    func blockedTerminalApplicationProhibited() {
        let script = "tell application \"Terminal\" to do script \"ls -la\""
        let report = AppleScriptSecurityAuditor.auditScript(script)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "BLOCKED_TARGET_APPLICATION" })
    }

    @Test("Empty script fails with EMPTY_APPLESCRIPT violation")
    func emptyScriptFails() {
        let report = AppleScriptSecurityAuditor.auditScript("   \n  ")

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "EMPTY_APPLESCRIPT" })
    }

    @Test("Malformed AppleScript syntax fails compilation check")
    func malformedSyntaxFailsCompilation() {
        let badScript = "tell application \"Unclosed string without closing quote"
        let (isCompiled, err) = AppleScriptSecurityAuditor.verifyCompilationSyntax(badScript)

        #expect(!isCompiled)
        #expect(err != nil)
        #expect(err?.isEmpty == false)
    }
}
