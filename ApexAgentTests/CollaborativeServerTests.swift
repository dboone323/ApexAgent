import Testing
import Foundation
import Network
@testable import ApexAgentCore

// Serialized: every case here reads or writes the process-wide
// UserDefaults keys the server consults ("apex.lanModeEnabled",
// "apex.collabToken"). Running them in parallel races on that shared
// state — which is what produced intermittent lanMode failures.
@MainActor
@Suite("CollaborativeServerTests", .serialized)
struct CollaborativeServerTests {
    private let server = CollaborativeServer.shared

    private static let lanKey = "apex.lanModeEnabled"
    private static let tokenKey = "apex.collabToken"

    /// Pin the defaults this suite depends on instead of inheriting whatever
    /// a previous `swift test` run leaked into the swiftpm-testing-helper
    /// defaults domain (that leak caused real false failures).
    init() {
        UserDefaults.standard.removeObject(forKey: Self.lanKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        CollaborativeServer.resetRateLimiter()
    }

    private func withLAN(enabled: Bool, token: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.lanKey)
        if let token { defaults.set(token, forKey: Self.tokenKey) }
        defer {
            defaults.removeObject(forKey: Self.lanKey)
            defaults.removeObject(forKey: Self.tokenKey)
        }
        body()
    }

    // MARK: - Defaults

    @Test func testDefaultBindsToLocalhost() async throws {
        let settings = server.health()
        #expect(settings.lanMode == false, "Default LAN mode must be off")
    }

    @Test func testHealthEndpointStructure() async throws {
        let settings = server.health()
        #expect(settings.running == false)
        #expect(settings.port == 1337)
        #expect(settings.lanMode == false)
    }

    // MARK: - Auth

    @Test func testLocalhostBypassesTokenAuth() async throws {
        let authorized = server.isAuthorized(
            headers: [:], queryToken: nil, connection: mockConnection(host: "127.0.0.1"))
        #expect(authorized == true)
    }

    @Test func testRemoteBlockedWithoutTokenWhenLanModeOff() async throws {
        let authorized = server.isAuthorized(
            headers: ["authorization": "Bearer bad"], queryToken: nil,
            connection: mockConnection(host: "192.168.1.50"))
        #expect(authorized == false)
    }

    /// A remote caller must present the *configured* token. An arbitrary
    /// bearer value must be rejected even when LAN mode is on.
    @Test func testRemoteRejectsUnknownBearerToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer not-the-real-token"], queryToken: nil,
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == false, "An unknown bearer token must never authorize a remote host")
        }
    }

    @Test func testRemoteAcceptsConfiguredBearerToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer the-real-token"], queryToken: nil,
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == true, "The configured token must authorize a remote host in LAN mode")
        }
    }

    @Test func testRemoteAcceptsConfiguredQueryToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: [:], queryToken: "the-real-token",
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == true)
        }
    }

    /// LAN mode with no token configured must fail closed, not open.
    @Test func testLanModeWithoutConfiguredTokenFailsClosed() async throws {
        withLAN(enabled: true, token: nil) {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer anything"], queryToken: nil,
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == false, "No configured token must deny remote access")
        }
    }

    // MARK: - Rate Limiting

    @Test func testRateLimiterResetsBetweenTests() async {
        CollaborativeServer.resetRateLimiter()
        #expect(CollaborativeServer.rateLimiters.isEmpty)
    }

    // MARK: - Audit log

    @Test func testAccessDecisionsAreLogged() async throws {
        let marker = "Allowed (200) \(UUID().uuidString)"
        server.logAccess(clientIP: "127.0.0.1", endpoint: "/", isAuthorized: true, decision: marker)

        let logLine = try readLastLogLine()
        #expect(logLine.contains(marker), "Access decision should be appended to the audit log")
    }

    // MARK: - Helpers

    private func mockConnection(host: String) -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 1337)!)
        return NWConnection(to: endpoint, using: .tcp)
    }

    private func readLastLogLine() throws -> String {
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ApexAgent")
        let logFileURL = logsDir.appendingPathComponent("collab-access.log")
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return "" }
        let content = try String(contentsOf: logFileURL, encoding: .utf8)
        return content.split(separator: "\n").last.map(String.init) ?? ""
    }
}
