import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Batch 68 — Network Diagnostics & Host Reachability Resilience Gate Tests")
struct NetworkResilienceAuditorTests {

    @Test("Safe external probes pass audit with score 100.0")
    func safeExternalProbesPass() {
        let probes = [
            NetworkProbeSpec(host: "api.github.com", port: 443, timeoutSeconds: 5.0),
            NetworkProbeSpec(host: "1.1.1.1", port: 53, timeoutSeconds: 3.0),
            NetworkProbeSpec(host: "localhost", port: 11434, timeoutSeconds: 2.0)
        ]

        let report = NetworkResilienceAuditor.audit(probes: probes)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.evaluatedProbesCount == 3)
        #expect(report.violations.isEmpty)
    }

    @Test("SSRF attempts targeting cloud metadata endpoints are rejected")
    func ssrfAttemptsAreRejected() {
        let metadataProbes = [
            NetworkProbeSpec(host: "169.254.169.254", port: 80),
            NetworkProbeSpec(host: "metadata.google.internal", port: 80),
            NetworkProbeSpec(host: "169.254.1.1", port: 8080)
        ]

        for p in metadataProbes {
            let report = NetworkResilienceAuditor.audit(probes: [p])
            #expect(!report.passed)
            #expect(report.violations.contains { $0.ruleId == "NET-002" && $0.severity == .critical })
        }
    }

    @Test("Command injection tokens in host parameter trigger critical violation")
    func commandInjectionInHostTriggerCriticalViolation() {
        let badHosts = [
            "google.com; cat /etc/passwd",
            "host.com | rm -rf /",
            "evil.com`whoami`",
            "malicious.com\0extra"
        ]

        for h in badHosts {
            let report = NetworkResilienceAuditor.audit(probes: [NetworkProbeSpec(host: h)])
            #expect(!report.passed)
            #expect(report.violations.contains { $0.ruleId == "NET-001" && $0.severity == .critical })
        }
    }

    @Test("Invalid and sensitive ports trigger appropriate violations")
    func portValidationDetectsViolations() {
        // Invalid port
        let invalidPortReport = NetworkResilienceAuditor.audit(probes: [NetworkProbeSpec(host: "apple.com", port: 99999)])
        #expect(!invalidPortReport.passed)
        #expect(invalidPortReport.violations.contains { $0.ruleId == "NET-003" && $0.severity == .critical })

        // Sensitive SSH port (medium severity, score 90 >= 80 passes)
        let sshReport = NetworkResilienceAuditor.audit(probes: [NetworkProbeSpec(host: "server.local", port: 22)])
        #expect(sshReport.passed)
        #expect(sshReport.violations.contains { $0.ruleId == "NET-004" && $0.severity == .medium })
    }

    @Test("Excessive or negligible timeouts trigger high violation")
    func timeoutValidationDetectsViolations() {
        let tooLong = NetworkProbeSpec(host: "example.com", port: 443, timeoutSeconds: 60.0)
        let report = NetworkResilienceAuditor.audit(probes: [tooLong])
        #expect(!report.passed)
        #expect(report.violations.contains { $0.ruleId == "NET-005" && $0.severity == .high })
    }

    @Test("computeLatencyStats computes correct percentiles")
    func computeLatencyStatsComputesPercentiles() {
        let samples = [10.0, 15.0, 20.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 100.0]
        let stats = NetworkResilienceAuditor.computeLatencyStats(samplesMs: samples)

        #expect(stats.min == 10.0)
        #expect(stats.max == 100.0)
        #expect(stats.p50 == 30.0 || stats.p50 == 35.0)
        #expect(stats.p95 == 100.0)
    }

    @Test("Report serializes to formatted JSON")
    func reportSerializesToJSON() {
        let report = NetworkResilienceAuditor.audit(probes: [])
        let json = report.toJSON()
        #expect(json.contains("\"passed\" : true"))
        #expect(json.contains("\"score\" : 100"))
    }
}
