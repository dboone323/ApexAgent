import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O5: Webhook receiver

@Suite("WebhookReceiverTests")
struct WebhookReceiverTests {

    private func makeManager(routine: String = "nightly-report") -> (WebhookManager, WebhookEndpoint) {
        let manager = WebhookManager()
        let endpoint = manager.addEndpoint(targetRoutineName: routine)
        return (manager, endpoint)
    }

    private func delivery(
        endpoint: WebhookEndpoint,
        method: String = "POST",
        pathOverride: String? = nil,
        auth: String? = nil,
        secretHeader: String? = nil,
        contentType: String? = nil,
        body: String? = nil,
        bodySize: Int? = nil,
        eventName: String? = nil,
        deliveryId: String? = nil
    ) -> WebhookDelivery {
        WebhookDelivery(
            method: method,
            path: pathOverride ?? "/hooks/\(endpoint.id)",
            authorizationHeader: auth,
            secretHeader: secretHeader,
            contentType: contentType,
            rawBody: body,
            bodySize: bodySize ?? (body?.utf8.count ?? 0),
            eventName: eventName,
            deliveryId: deliveryId)
    }

    @Test func endpointIdsAndSecretsAreWellFormed() {
        let (_, endpoint) = makeManager()
        #expect(endpoint.id.hasPrefix("wh_"))
        #expect(endpoint.id.range(of: #"^wh_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil)
        #expect(endpoint.secret.count == 32)
    }

    @Test func healthProbeNeedsNoAuth() {
        let (manager, _) = makeManager()
        let placeholder = WebhookEndpoint(id: "x", secret: "s", targetRoutineName: "")
        let request = delivery(endpoint: placeholder, method: "GET", pathOverride: "/health")
        #expect(WebhookRouter.route(manager: manager, request: request).statusCode == 202)
    }

    @Test func unknownPathAndWrongMethodRejected() {
        let (manager, endpoint) = makeManager()
        let bad404 = WebhookRouter.route(manager: manager, request: delivery(endpoint: endpoint, pathOverride: "/hooks/not_a_hook"))
        #expect(bad404.statusCode == 404)

        let get = WebhookRouter.route(manager: manager, request: delivery(endpoint: endpoint, method: "GET"))
        #expect(get.statusCode == 405)
    }

    @Test func wrongSecretIsUnauthorized() {
        let (manager, endpoint) = makeManager()
        let outcome = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, auth: "Bearer wrong-secret"))
        #expect(outcome.statusCode == 401)
    }

    @Test func bearerAndPathSecretsBothAuthorize() {
        var triggered = 0
        let (manager, endpoint) = makeManager()

        let viaBearer = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, auth: "Bearer \(endpoint.secret)", contentType: "application/json", body: "{}")) { _, _, _, _ in triggered += 1 }
        #expect(viaBearer.statusCode == 202)
        #expect(triggered == 1)

        let viaCapabilityURL = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, pathOverride: "/hooks/\(endpoint.id)/\(endpoint.secret)", contentType: "application/json", body: "{}")) { _, _, _, _ in triggered += 1 }
        #expect(viaCapabilityURL.statusCode == 202)
        #expect(triggered == 2)
    }

    @Test func oversizedBodyRejectedBeforeParsing() {
        let (manager, endpoint) = makeManager()
        let big = String(repeating: "a", count: WebhookManager.maxBodyBytes + 1)
        let outcome = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, auth: "Bearer \(endpoint.secret)", body: big))
        #expect(outcome.statusCode == 413)
    }

    @Test func invalidJSONRejectedWith400() {
        let (manager, endpoint) = makeManager()
        let outcome = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, auth: "Bearer \(endpoint.secret)", contentType: "application/json", body: "{not json"))
        #expect(outcome.statusCode == 400)
    }

    @Test func jsonPayloadTriggersTargetRoutine() {
        let (manager, endpoint) = makeManager()
        var routedName: String?
        var payload: WebhookPayload?
        let outcome = WebhookRouter.route(
            manager: manager,
            request: delivery(
                endpoint: endpoint,
                auth: "Bearer \(endpoint.secret)",
                contentType: "application/json",
                body: #"{"issue": "build red", "n": 3}"#,
                eventName: "push",
                deliveryId: "d-1")) { ep, p, event, id in
                routedName = ep.targetRoutineName
                payload = p
                #expect(event == "push")
                #expect(id == "d-1")
            }
        #expect(outcome.statusCode == 202)
        #expect(routedName == "nightly-report")
        if case .json(let dict)? = payload {
            #expect(dict["issue"] == "build red")
        } else {
            Issue.record("expected json payload")
        }
    }

    @Test func formPayloadParsesUrlEncodedBody() {
        let (manager, endpoint) = makeManager()
        var payload: WebhookPayload?
        _ = WebhookRouter.route(
            manager: manager,
            request: delivery(
                endpoint: endpoint,
                secretHeader: endpoint.secret,
                contentType: "application/x-www-form-urlencoded",
                body: "status=green&run=7")) { _, p, _, _ in payload = p }
        if case .form(let dict)? = payload {
            #expect(dict["status"] == "green")
            #expect(dict["run"] == "7")
        } else {
            Issue.record("expected form payload")
        }
    }

    @Test func duplicateDeliveryIdDoesNotTriggerTwice() {
        let (manager, endpoint) = makeManager()
        var triggers = 0
        let request = delivery(
            endpoint: endpoint,
            auth: "Bearer \(endpoint.secret)",
            contentType: "application/json",
            body: "{}",
            deliveryId: "gh-delivery-42")

        let first = WebhookRouter.route(manager: manager, request: request) { _, _, _, _ in triggers += 1 }
        let second = WebhookRouter.route(manager: manager, request: request) { _, _, _, _ in triggers += 1 }

        #expect(first.statusCode == 202 && second.statusCode == 202)
        if case .accepted(_, _, let duplicate) = second {
            #expect(duplicate)
        } else {
            Issue.record("expected accepted-duplicate")
        }
        #expect(triggers == 1)
    }

    @Test func disabledEndpointRejectsEvenWithValidSecret() {
        let (manager, endpoint) = makeManager()
        manager.setEnabled(id: endpoint.id, enabled: false)
        let outcome = WebhookRouter.route(
            manager: manager,
            request: delivery(endpoint: endpoint, auth: "Bearer \(endpoint.secret)"))
        #expect(outcome.statusCode == 401)
    }
}
