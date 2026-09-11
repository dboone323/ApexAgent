import Testing
import Foundation
import Network
@testable import ApexAgentCore

// MARK: - Chief-of-staff wiring through BotSession

@MainActor
@Suite("ChiefOfStaffSessionTests")
struct ChiefOfStaffSessionTests {

    @Test func chiefSessionInstructionsIncludeLiveRoster() {
        let orchestrator = AgentOrchestrator()
        let manager = BotManager(orchestrator: orchestrator, computer: Computer())

        let chief = manager.createBot(name: "Chief", title: "Coordinator", descriptionText: "Own outcomes.")
        chief.isChiefOfStaff = true
        _ = manager.createBot(name: "Prospector", title: "Outbound", descriptionText: "Researches accounts.")

        let instructions = manager.session(for: chief).systemInstructions
        // Base persona comes first…
        #expect(instructions.hasPrefix("You are Chief."))
        // …then the live roster appended by the chief-of-staff layer.
        #expect(instructions.contains("Chief of Staff for the General section"))
        #expect(instructions.contains("- Prospector — Outbound"))
        #expect(instructions.contains("(available)"))

        // Non-chief sessions are untouched.
        guard let prospector = manager.botByName("Prospector") else {
            Issue.record("missing prospector"); return
        }
        #expect(!manager.session(for: prospector).systemInstructions.contains("Chief of Staff"))
    }

    @Test func duplicatePreservesChiefFlagAndBackReference() {
        let orchestrator = AgentOrchestrator()
        let manager = BotManager(orchestrator: orchestrator, computer: Computer())
        let original = manager.createBot(name: "Boss", title: "", descriptionText: "")
        original.isChiefOfStaff = true

        let copy = manager.duplicateBot(original)
        #expect(copy.isChiefOfStaff == true)
        let copySession = manager.session(for: copy)
        _ = manager.createBot(name: "Teammate", title: "", descriptionText: "")
        #expect(copySession.systemInstructions.contains("- Teammate"))
        // The back-reference survived, otherwise no roster would appear.
        #expect(copySession.botManager === manager)
    }
}

// MARK: - Routine webhook dispatch glue

@MainActor
@Suite("RoutineWebhookDispatchTests")
struct RoutineWebhookDispatchTests {

    @Test func dispatchWebhookWithoutMatchingRoutineReturnsNilGracefully() async {
        let result = await RoutineManager.shared.dispatchWebhook(
            routineName: "no-such-routine-\(UUID().uuidString)")
        #expect(result == nil)
    }
}

// MARK: - O5 live socket front

@Suite("WebhookServerTests")
struct WebhookServerTests {

    @Test func parsesHeadBodySplitAndContentLength() {
        let raw = Data("POST /hooks/wh_x HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        guard let (head, body) = WebhookServer.splitHeadAndBody(raw) else {
            Issue.record("expected head/body split"); return
        }
        #expect(WebhookServer.contentLength(head) == 5)
        #expect(String(decoding: body, as: UTF8.self) == "hello")
    }

    @Test func liveServerAcceptsAuthorizedDeliveryAndRejectsBadSecret() async throws {
        let manager = WebhookManager()
        let endpoint = manager.addEndpoint(targetRoutineName: "nightly-report")
        var triggered = 0

        let server = WebhookServer(manager: manager)
        server.onAccepted = { _, _, _, _ in triggered += 1 }
        try server.start(preferredPort: 0)
        defer { server.stop() }
        #expect(server.port > 0)

        let url = URL(string: "http://127.0.0.1:\(server.port)/hooks/\(endpoint.id)")!

        // Authorized POST → 202 and one trigger.
        var good = URLRequest(url: url)
        good.httpMethod = "POST"
        good.setValue("Bearer \(endpoint.secret)", forHTTPHeaderField: "Authorization")
        good.setValue("application/json", forHTTPHeaderField: "Content-Type")
        good.setValue("gh-delivery-9", forHTTPHeaderField: "Idempotency-Key")
        good.httpBody = Data(#"{"status": "green"}"#.utf8)

        let (data, goodResponse) = try await URLSession.shared.data(for: good)
        #expect((goodResponse as? HTTPURLResponse)?.statusCode == 202)
        let bodyText = String(decoding: data, as: UTF8.self)
        #expect(bodyText.contains(#""accepted":true"#))
        #expect(bodyText.contains("nightly-report"))
        try await Task.sleep(for: .milliseconds(150))
        #expect(triggered == 1)

        // Same delivery id again → accepted duplicate, still one trigger.
        _ = try await URLSession.shared.data(for: good)
        try await Task.sleep(for: .milliseconds(150))
        #expect(triggered == 1)

        // Wrong secret → 401.
        var bad = URLRequest(url: url)
        bad.httpMethod = "POST"
        bad.setValue("Bearer definitely-wrong", forHTTPHeaderField: "Authorization")
        bad.httpBody = Data("{}".utf8)
        let (badData, badResponse) = try await URLSession.shared.data(for: bad)
        #expect((badResponse as? HTTPURLResponse)?.statusCode == 401)
        #expect(String(decoding: badData, as: UTF8.self).contains(#""accepted":false"#))
        #expect(triggered == 1)
    }
}
