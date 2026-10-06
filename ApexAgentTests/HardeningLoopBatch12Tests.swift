import Testing
import Foundation
import Network
@testable import ApexAgentCore

@Suite("HardeningLoopBatch12Tests")
struct HardeningLoopBatch12Tests {
    @Test func testMCPServerConfigValidation() {
        var cfg = MCPServerConfig(name: "", command: "npx", arguments: [])
        #expect(!cfg.isValid)
        #expect(cfg.validationError() != nil)
        cfg = MCPServerConfig(name: "FS", command: "npx", arguments: ["-y", "x"])
        #expect(cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: nil)
        #expect(!cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: "ftp://bad")
        #expect(!cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "http", endpointURL: "https://ok/hooks")
        #expect(cfg.isValid)
        cfg = MCPServerConfig(name: "W", command: "x", arguments: [], transport: "carrier-pigeon")
        #expect(!cfg.isValid)
    }

    @Test func testMCPClientConfigClamped() {
        let bad = MCPClientConfig(requestTimeout: -5, pingTimeout: 5000, maxRetries: 999, circuitFailureThreshold: 0, restartRateLimitWindow: -1, maxRestartsInWindow: 999)
        let c = bad.clamped()
        #expect(c.requestTimeout >= 1 && c.requestTimeout <= 600)
        #expect(c.pingTimeout >= 0.5 && c.pingTimeout <= 60)
        #expect(c.maxRetries <= 20)
        #expect(c.circuitFailureThreshold >= 1)
        #expect(c.maxRestartsInWindow <= 50)
    }

    @Test func testDimensionScoreValidated() {
        let s = DimensionScore.validated(dimension: .toolCalling, passedChecks: 99, totalChecks: 5, notes: "clamped")
        #expect(s.passedChecks == 5)
        #expect(s.totalChecks == 5)
        let s2 = DimensionScore.validated(dimension: .toolCalling, passedChecks: -3, totalChecks: 5)
        #expect(s2.passedChecks == 0)
    }

    @Test func testCronValidated() {
        #expect(CronSchedule.validated(expression: "not a cron") == nil)
        #expect(CronSchedule.validated(expression: "0 9 * * 1-5") != nil)
        #expect(CronSchedule.validationMessage(for: "junk").contains("Invalid"))
        #expect(CronSchedule.validationMessage(for: "0 9 * * 1-5").contains("Valid"))
    }

    @Test func testWebhookEndpointIdShape() {
        #expect(WebhookManager.isPlausibleEndpointId("wh_abc12345"))
        #expect(!WebhookManager.isPlausibleEndpointId("bogus"))
        #expect(!WebhookManager.isPlausibleEndpointId("wh_"))
        let mgr = WebhookManager()
        #expect(!mgr.authorizeValidated(id: "bogus", secret: "x"))
        #expect(!mgr.authorizeValidated(id: "wh_abc12345", secret: ""))
    }

    @Test func testWebhookDeliveryPreflight() {
        var d = WebhookDelivery(path: "/hooks/wh_x", bodySize: 10)
        #expect(d.preflightError() == nil)
        d = WebhookDelivery(path: "/hooks/wh_x", bodySize: WebhookManager.maxBodyBytes + 1)
        #expect(d.preflightError() != nil)
        var d2 = WebhookDelivery(method: "DELETE", path: "/hooks/wh_x", bodySize: 0)
        #expect(d2.preflightError() != nil)
        d2 = WebhookDelivery(path: "/elsewhere", bodySize: 0)
        #expect(d2.preflightError() != nil)
    }

    @Test @MainActor func testPeerDedup() {
        let ep = NWEndpoint.hostPort(host: .ipv4(.loopback), port: 1338)
        let older = A2APeerDiscovery.DiscoveredPeer(id: UUID(), name: "a", endpoint: ep, discoveredAt: Date(timeIntervalSince1970: 100))
        let newer = A2APeerDiscovery.DiscoveredPeer(id: UUID(), name: "b", endpoint: ep, discoveredAt: Date(timeIntervalSince1970: 200))
        let result = A2APeerDiscovery.deduplicatedPeers([older, newer])
        #expect(result.count == 1)
        #expect(result.first?.name == "b")
        #expect(A2APeerDiscovery.deduplicatedPeers([]).isEmpty)
    }
}
