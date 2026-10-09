import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Deep Link Route Gate Security Tests")
struct DeepLinkRouteGateTests {
    @Test("Verifies bidirectional roundtrip bijection for all destination variants")
    func bidirectionalBijectionForAllDestinations() {
        let destinations: [DeepLinkDestination] = [
            .chat(id: "session-01a2b3c4"),
            .routine(id: "daily-sync-routine"),
            .skill(name: "swift-syntax-refactor"),
            .diagnostics,
            .settings,
            .command(name: "doctor")
        ]

        for dest in destinations {
            let matches = DeepLinkRouteGate.verifyBijection(destination: dest)
            #expect(matches)
        }

        let report = DeepLinkRouteGate.audit(urls: [], testDestinations: destinations)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.violations.isEmpty)

        let md = report.toMarkdown()
        #expect(md.contains("PASS"))
        #expect(md.contains("100.0/100.0"))
    }

    @Test("Detects path traversal attempts in deep link URLs")
    func pathTraversalDetection() {
        let badURL = URL(string: "apexagent://chat/../../etc/passwd")!
        let (action, violations) = DeepLinkRouteGate.evaluateURL(badURL)

        #expect(!action.isPermitted)
        let hasTraversalViolation = violations.contains { $0.ruleId == "deeplink_path_traversal" }
        #expect(hasTraversalViolation)
    }

    @Test("Detects foreign URL scheme injection in deep links")
    func foreignSchemeInjectionDetection() {
        let badURL = URL(string: "apexagent://chat/https://evil-hacker.com/steal-creds")!
        let (action, violations) = DeepLinkRouteGate.evaluateURL(badURL)

        #expect(!action.isPermitted)
        let hasInjectionViolation = violations.contains { $0.ruleId == "deeplink_url_injection" }
        #expect(hasInjectionViolation)
    }

    @Test("Sanitizes query parameters by stripping script injections")
    func queryParameterSanitization() {
        let targetURL = URL(string: "apexagent://chat/12345?query=safe&payload=<script>alert('xss')</script>&tag=production")!
        let (action, _) = DeepLinkRouteGate.evaluateURL(targetURL)

        #expect(action.sanitizedParameters["query"] == "safe")
        #expect(action.sanitizedParameters["tag"] == "production")
        #expect(action.sanitizedParameters["payload"] == nil)
    }

    @Test("Detects scheme mismatch for non-apexagent links")
    func schemeMismatchDetection() {
        let badURL = URL(string: "https://apexagent.local/chat/12345")!
        let (action, violations) = DeepLinkRouteGate.evaluateURL(badURL)

        #expect(!action.isPermitted)
        let hasSchemeViolation = violations.contains { $0.ruleId == "deeplink_scheme_mismatch" }
        #expect(hasSchemeViolation)
    }
}
