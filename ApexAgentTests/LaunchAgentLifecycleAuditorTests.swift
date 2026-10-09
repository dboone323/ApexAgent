import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 80 — LaunchAgent Plist & Socket Activation Lifecycle Gate Tests")
struct LaunchAgentLifecycleAuditorTests {

    @Test("Standard daemon configuration passes audit with 100% score")
    func standardConfigPasses() {
        let config = LaunchAgentConfig(
            label: "com.apexagent.daemon",
            programPath: "/Applications/ApexAgent.app/Contents/MacOS/ApexAgent",
            arguments: ["--daemon"],
            runAtLoad: true,
            keepAlive: true
        )

        let report = LaunchAgentLifecycleAuditor.auditConfig(config)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.labelValid)
        #expect(report.executablePathValid)
        #expect(report.logPathsSandboxed)
        #expect(report.violations.isEmpty)
    }

    @Test("Generated XML plist deserializes and passes audit cleanly")
    func generatedXMLPlistPasses() {
        let config = LaunchAgentConfig(
            label: "com.apexagent.daemon.worker",
            programPath: "/usr/local/bin/apexagent",
            arguments: ["--daemon", "--port", "1337"]
        )

        let xml = LaunchAgentPlist.xml(for: config)
        let report = LaunchAgentLifecycleAuditor.auditPlistXML(xml)

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.labelValid)
        #expect(report.executablePathValid)
        #expect(report.logPathsSandboxed)
        #expect(report.violations.isEmpty)
    }

    @Test("Relative executable path or invalid label triggers fatal violations")
    func relativePathAndBadLabelFail() {
        let badConfig = LaunchAgentConfig(
            label: "apexagent", // Missing reverse-DNS prefix
            programPath: "bin/apexagent", // Relative path!
            arguments: []
        )

        let report = LaunchAgentLifecycleAuditor.auditConfig(badConfig)
        #expect(!report.passed)
        #expect(!report.labelValid)
        #expect(!report.executablePathValid)
        #expect(report.violations.contains { $0.code == "INVALID_LABEL_FORMAT" })
        #expect(report.violations.contains { $0.code == "RELATIVE_EXECUTABLE_PATH" })
    }

    @Test("Malformed XML triggers MALFORMED_PLIST_XML violation")
    func malformedXMLFails() {
        let brokenXML = "<dict><key>broken</dict>"
        let report = LaunchAgentLifecycleAuditor.auditPlistXML(brokenXML)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "MALFORMED_PLIST_XML" })
    }

    @Test("Shutdown grace period validates realistic boundary constraints")
    func shutdownGracePeriodValidation() {
        #expect(LaunchAgentLifecycleAuditor.validateShutdownGracePeriod(gracePeriodSeconds: 10.0))
        #expect(LaunchAgentLifecycleAuditor.validateShutdownGracePeriod(gracePeriodSeconds: 5.0))
        #expect(!LaunchAgentLifecycleAuditor.validateShutdownGracePeriod(gracePeriodSeconds: 1.0)) // Too short
        #expect(!LaunchAgentLifecycleAuditor.validateShutdownGracePeriod(gracePeriodSeconds: 60.0)) // Too long
    }
}
