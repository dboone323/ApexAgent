import Testing
import Foundation
import Network
@testable import ApexAgentCore

// Serialized: every case here reads or writes the process-wide state the
// server consults ("apex.lanModeEnabled" in UserDefaults, the LAN token in
// the Keychain). Running them in parallel races on that shared state —
// which is what produced intermittent lanMode failures.
@MainActor
@Suite("CollaborativeServerTests", .serialized)
struct CollaborativeServerTests {
    private let server = CollaborativeServer.shared

    private static let lanKey = "apex.lanModeEnabled"
    private static let tokenKey = "apex.collabToken"

    /// Pin the state this suite depends on instead of inheriting whatever
    /// a previous `swift test` run leaked into the swiftpm-testing-helper
    /// defaults domain (that leak caused real false failures).
    init() {
        UserDefaults.standard.removeObject(forKey: Self.lanKey)
        // M1: the token now lives in the Keychain (the legacy UserDefaults
        // slot is cleared for hygiene).
        KeychainManager.delete(key: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        CollaborativeServer.resetRateLimiter()
        CollaborativeServer.resetInviteCodes()
    }

    private func withLAN(enabled: Bool, token: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.lanKey)
        // M1: configure the token where the server reads it — the Keychain.
        if let token { KeychainManager.save(key: Self.tokenKey, value: token) }
        defer {
            defaults.removeObject(forKey: Self.lanKey)
            KeychainManager.delete(key: Self.tokenKey)
        }
        body()
    }

    private func withLANAsync(enabled: Bool, token: String?, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        defaults.set(enabled, forKey: Self.lanKey)
        if let token { KeychainManager.save(key: Self.tokenKey, value: token) }
        defer {
            defaults.removeObject(forKey: Self.lanKey)
            KeychainManager.delete(key: Self.tokenKey)
        }
        try await body()
    }

    // MARK: - Defaults

    @Test func testDefaultBindsToLocalhost() async throws {
        let settings = server.health()
        #expect(settings.lanMode == false, "Default LAN mode must be off")
    }

    @Test func testHealthEndpointStructure() async throws {
        let settings = server.health()
        #expect(settings.running == false)
        #expect(settings.port == 1340)
        #expect(settings.lanMode == false)
    }

    // MARK: - Auth

    @Test func testLocalhostRequiresTokenAuthByDefault() async throws {
        let authorized = server.isAuthorized(
            headers: [:], connection: mockConnection(host: "127.0.0.1"))
        #expect(authorized == false, "Unauthenticated localhost requests must be rejected by default to prevent screen/state extraction")
    }

    @Test func testLocalhostBypassesTokenAuthWhenExplicitlyAllowed() async throws {
        UserDefaults.standard.set(true, forKey: "apex.collabAllowUnauthenticatedLoopback")
        defer { UserDefaults.standard.removeObject(forKey: "apex.collabAllowUnauthenticatedLoopback") }
        let authorized = server.isAuthorized(
            headers: [:], connection: mockConnection(host: "127.0.0.1"))
        #expect(authorized == true)
    }

    @Test func testLocalhostAuthorizedWithBearerToken() async throws {
        withLAN(enabled: false, token: "local-secret") {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer local-secret"],
                connection: mockConnection(host: "127.0.0.1"))
            #expect(authorized == true, "Localhost caller presenting configured token must be authorized")
        }
    }

    @Test func testRemoteBlockedWithoutTokenWhenLanModeOff() async throws {
        let authorized = server.isAuthorized(
            headers: ["authorization": "Bearer bad"],
            connection: mockConnection(host: "192.168.1.50"))
        #expect(authorized == false)
    }

    /// A remote caller must present the *configured* token. An arbitrary
    /// bearer value must be rejected even when LAN mode is on.
    @Test func testRemoteRejectsUnknownBearerToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer not-the-real-token"],
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == false, "An unknown bearer token must never authorize a remote host")
        }
    }

    @Test func testRemoteAcceptsConfiguredBearerToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer the-real-token"],
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == true, "The configured token must authorize a remote host in LAN mode")
        }
    }

    @Test func testRemoteAcceptsConfiguredSessionCookie() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let authorized = server.isAuthorized(
                headers: ["cookie": "apex_session=the-real-token"],
                connection: mockConnection(host: "10.0.0.1"))
            #expect(authorized == true, "A valid apex_session cookie must authorize a remote host in LAN mode")
        }
    }

    /// RED proof test: a request carrying ONLY ?token=<valid token> must be rejected with 401.
    @Test func testRequestWithOnlyQueryTokenIsRejected() async throws {
        try await withLANAsync(enabled: true, token: "test-auth-token") {
            let serverInstance = CollaborativeServer()
            serverInstance.start(port: 0)
            defer { serverInstance.stop() }

            var waited = 0
            while !serverInstance.isRunning && waited < 3_000 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 50
            }
            #expect(serverInstance.isRunning)
            let port = serverInstance.port

            let url = URL(string: "http://127.0.0.1:\(port)/api/state?token=test-auth-token")!
            let request = URLRequest(url: url)
            let (_, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 401, "A request carrying only ?token= must be rejected with 401")
        }
    }

    /// GREEN proof test (b): the same request as testRequestWithOnlyQueryTokenIsRejected,
    /// but with Authorization: Bearer <token> succeeds (200).
    @Test func testRequestWithBearerHeaderSucceeds() async throws {
        try await withLANAsync(enabled: true, token: "test-auth-token") {
            let serverInstance = CollaborativeServer()
            serverInstance.start(port: 0)
            defer { serverInstance.stop() }

            var waited = 0
            while !serverInstance.isRunning && waited < 3_000 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 50
            }
            #expect(serverInstance.isRunning)
            let port = serverInstance.port

            let url = URL(string: "http://127.0.0.1:\(port)/api/state")!
            var request = URLRequest(url: url)
            request.setValue("Bearer test-auth-token", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = try #require(response as? HTTPURLResponse)
            #expect(httpResponse.statusCode == 200, "A request with Authorization: Bearer <token> must succeed with 200")
            #expect(!data.isEmpty, "Response data should not be empty")
        }
    }

    /// GREEN proof test (c): redeeming a valid invite code returns/sets a session (cookie)
    /// that authenticates a subsequent request, AND reusing the same redeemed code fails.
    @Test func testInviteCodeRedemptionSetsSessionCookieAndPreventsReuse() async throws {
        try await withLANAsync(enabled: true, token: "test-session-token") {
            let serverInstance = CollaborativeServer()
            serverInstance.start(port: 0)
            defer { serverInstance.stop() }

            var waited = 0
            while !serverInstance.isRunning && waited < 3_000 {
                try? await Task.sleep(for: .milliseconds(50))
                waited += 50
            }
            #expect(serverInstance.isRunning)
            let port = serverInstance.port

            // Step 1: Issue an invite code
            let code = CollaborativeServer.issueInviteCode()

            // Step 2: Redeem the invite code
            let redeemURL = URL(string: "http://127.0.0.1:\(port)/api/redeem?code=\(code)")!
            let redeemRequest = URLRequest(url: redeemURL)
            let (redeemData, redeemResponse) = try await URLSession.shared.data(for: redeemRequest)
            let redeemHTTP = try #require(redeemResponse as? HTTPURLResponse)
            #expect(redeemHTTP.statusCode == 200, "Redeeming a valid invite code must succeed with 200")

            // Verify Set-Cookie header contains apex_session=<token>
            let setCookie = redeemHTTP.value(forHTTPHeaderField: "Set-Cookie") ?? ""
            #expect(setCookie.contains("apex_session=test-session-token"), "Set-Cookie header must contain apex_session=<token>")
            #expect(setCookie.contains("HttpOnly"), "Session cookie must be HttpOnly")

            // Verify body contains token JSON
            let bodyString = String(data: redeemData, encoding: .utf8) ?? ""
            #expect(bodyString.contains("\"token\":\"test-session-token\""), "Redemption response must return session token JSON")

            // Step 3: Make subsequent request using the apex_session cookie
            let stateURL = URL(string: "http://127.0.0.1:\(port)/api/state")!
            var authenticatedRequest = URLRequest(url: stateURL)
            authenticatedRequest.setValue("apex_session=test-session-token", forHTTPHeaderField: "Cookie")
            let (stateData, stateResponse) = try await URLSession.shared.data(for: authenticatedRequest)
            let stateHTTP = try #require(stateResponse as? HTTPURLResponse)
            #expect(stateHTTP.statusCode == 200, "Subsequent request with apex_session cookie must succeed with 200")
            #expect(!stateData.isEmpty, "State response data should not be empty")

            // Step 4: Reusing the same redeemed invite code must fail with 403 Forbidden
            let reuseRequest = URLRequest(url: redeemURL)
            let (reuseData, reuseResponse) = try await URLSession.shared.data(for: reuseRequest)
            let reuseHTTP = try #require(reuseResponse as? HTTPURLResponse)
            #expect(reuseHTTP.statusCode == 403, "Reusing a redeemed invite code must fail with 403")
            let reuseBody = String(data: reuseData, encoding: .utf8) ?? ""
            #expect(reuseBody.contains("Invalid or expired invite code"), "Reuse rejection body should explain invalid/expired code")
        }
    }

    /// LAN mode with no token configured must fail closed, not open.
    @Test func testLanModeWithoutConfiguredTokenFailsClosed() async throws {
        withLAN(enabled: true, token: nil) {
            let authorized = server.isAuthorized(
                headers: ["authorization": "Bearer anything"],
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

    // MARK: - Invite redemption (F10)

    @Test func testInviteCodeSingleUse() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let code = CollaborativeServer.issueInviteCode()
            let first = CollaborativeServer.redeemInviteCode(code)
            #expect(first == "the-real-token")
            let second = CollaborativeServer.redeemInviteCode(code)
            #expect(second == nil, "Invite code must be single-use")
        }
    }

    @Test func testInviteCodeExpiry() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            let code = CollaborativeServer.issueInviteCode(ttl: -1)
            #expect(CollaborativeServer.isInviteCodeValid(code) == false)
            let redeemed = CollaborativeServer.redeemInviteCode(code)
            #expect(redeemed == nil, "Expired invite code must not redeem")
        }
    }

    @Test func testInviteCodeUnknownRejected() async throws {
        #expect(CollaborativeServer.redeemInviteCode("does-not-exist") == nil)
    }

    // MARK: - RBAC (F10)

    @Test func testHasPermissionDeniedForUnknownToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            #expect(CollaborativeServer.shared.hasPermission(token: "bogus", requiredPermission: "read:state") == false)
            #expect(CollaborativeServer.shared.hasPermission(token: "", requiredPermission: "read:state") == false)
        }
    }

    @Test func testHasPermissionGrantedForValidToken() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            #expect(CollaborativeServer.shared.hasPermission(token: "the-real-token", requiredPermission: "read:state") == true)
            #expect(CollaborativeServer.shared.hasPermission(token: "the-real-token", requiredPermission: "write:spaces") == true)
        }
    }

    @Test func testHasPermissionDeniedForUnknownPermission() async throws {
        withLAN(enabled: true, token: "the-real-token") {
            #expect(CollaborativeServer.shared.hasPermission(token: "the-real-token", requiredPermission: "admin:nuke") == false)
        }
    }

    private func mockConnection(host: String) -> NWConnection {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: 1337)!)
        return NWConnection(to: endpoint, using: .tcp)
    }

    private func readLastLogLine() throws -> String {
        let logsDir = ApexAgentStoragePaths.collaborationLogs
        let logFileURL = logsDir.appendingPathComponent("collab-access.log")
        guard FileManager.default.fileExists(atPath: logFileURL.path) else { return "" }
        let content = try String(contentsOf: logFileURL, encoding: .utf8)
        return content.split(separator: "\n").last.map(String.init) ?? ""
    }
}
