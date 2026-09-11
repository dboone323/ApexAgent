import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O5: Webhook receiver (port of OpenMausBot webhook-ingress.ts)

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

// MARK: - O7: Chief of Staff roster prompt (port of OpenMausBot chief-of-staff.ts)

@Suite("ChiefOfStaffTests")
struct ChiefOfStaffTests {

    private func member(id: String, name: String, section: String? = nil,
                        title: String? = nil, busy: Bool = false, hidden: Bool = false) -> ChiefTeamMember {
        ChiefTeamMember(id: id, name: name, title: title, descriptionText: nil,
                        busy: busy, hidden: hidden, section: section)
    }

    @Test func promptNamesSectionAndListsAvailableTeammates() {
        let bots = [
            member(id: "chief", name: "Chief", section: "Sales"),
            member(id: "a", name: "Prospector", section: "Sales", title: "Outbound", busy: false),
            member(id: "b", name: "Closer", section: "Sales", title: "Deals", busy: true),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(prompt.contains("Chief of Staff for the Sales section"))
        #expect(prompt.contains("- Prospector — Outbound (available)"))
        #expect(prompt.contains("- Closer — Deals (working right now)"))
    }

    @Test func hiddenAndOtherSectionBotsExcluded() {
        let bots = [
            member(id: "chief", name: "Chief", section: "Sales"),
            member(id: "hidden", name: "SecretSquirrel", section: "Sales", hidden: true),
            member(id: "other", name: "OpsPerson", section: "Ops"),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(!prompt.contains("SecretSquirrel"))
        #expect(!prompt.contains("OpsPerson"))
        #expect(prompt.contains("No other visible bots"))
    }

    @Test func longNamesAreClippedToCaps() {
        let longName = String(repeating: "x", count: 200)
        let bots = [
            member(id: "chief", name: "Chief"),
            member(id: "long", name: longName),
        ]
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: bots, canDelegate: true)
        #expect(prompt.contains(String(repeating: "x", count: 79) + "…"))
        #expect(!prompt.contains(longName))
    }

    @Test func noDelegationEngineIsHonest() {
        let prompt = ChiefOfStaff.systemPrompt(chiefId: "chief", bots: [], canDelegate: false)
        #expect(prompt.contains("cannot contact teammates"))
        #expect(!prompt.contains("Use ask-bot when a teammate"))
    }
}

// MARK: - O8: Skill catalog manifests + trigger matching

@Suite("SkillCatalogTests")
struct SkillCatalogTests {

    private func manifestJSON(id: String = "release-notes",
                              version: String = "1.0.0",
                              triggerTerms: [String] = ["release notes", "changelog"],
                              defaultEnabled: Any = true,
                              requiredCapabilities: [String]? = ["filesystem"]) -> [String: Any] {
        [
            "id": id,
            "name": "Release Notes",
            "version": version,
            "description": "Writes release notes from commits",
            "defaultEnabled": defaultEnabled,
            "triggerTerms": triggerTerms,
            "requiredCapabilities": requiredCapabilities as Any,
        ]
    }

    @Test func validManifestParses() throws {
        let manifest = try SkillCatalog.parseManifest(manifestJSON(), directoryName: "release-notes")
        #expect(manifest.id == "release-notes")
        #expect(manifest.triggerTerms.count == 2)
        #expect(manifest.requiredCapabilities == ["filesystem"])
        #expect(manifest.defaultEnabled == true)
    }

    @Test func invalidIdOrVersionRejected() throws {
        let badId = manifestJSON(id: "Bad_Id")
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(badId, directoryName: "bad-id")
        }
        let badVersion = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: [
            "id": "release-notes", "name": "n", "version": "1.0",
            "description": "d", "defaultEnabled": true, "triggerTerms": ["x"],
            "requiredCapabilities": [],
        ])) 
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(badVersion, directoryName: "release-notes")
        }
    }

    @Test func missingTriggerTermsRejected() throws {
        let noTerms = manifestJSON(triggerTerms: [])
        #expect(throws: (any Error).self) {
            try SkillCatalog.parseManifest(noTerms, directoryName: "release-notes")
        }
    }

    @Test func loaderIsolatesBrokenFoldersAndLoadsGoodOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skills-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let good = root.appendingPathComponent("release-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifestJSON())
            .write(to: good.appendingPathComponent("manifest.json"))
        try "# Release Notes\nWrite them.".write(
            to: good.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let broken = root.appendingPathComponent("broken-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try "{}".write(to: broken.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)

        let loaded = SkillCatalog.loadSkills(root: root)
        #expect(loaded.count == 1)
        #expect(loaded.first?.manifest.id == "release-notes")
    }

    @Test func triggerMatchingRespectsEnablement() throws {
        let skills: [(manifest: SkillManifest, instructions: String)] = [
            (try SkillCatalog.parseManifest(manifestJSON(), directoryName: "release-notes"), ""),
            (try SkillCatalog.parseManifest(
                manifestJSON(id: "expenses", triggerTerms: ["expense report"], defaultEnabled: false),
                directoryName: "expenses"), ""),
        ]
        let hitRelease = SkillCatalog.matchingSkills(prompt: "please draft release notes", skills: skills)
        #expect(hitRelease.map(\.id) == ["release-notes"])

        // Disabled-by-default skill only matches when explicitly enabled.
        #expect(SkillCatalog.matchingSkills(prompt: "file an expense report", skills: skills).isEmpty)
        let enabled = SkillCatalog.matchingSkills(
            prompt: "file an expense report", skills: skills, enabledIds: ["expenses"])
        #expect(enabled.map(\.id) == ["expenses"])
    }

    @Test func termsRoundTripThroughJSON() {
        let encoded = SkillCatalog.encodeTerms(["release notes", "changelog"])
        #expect(SkillCatalog.decodeTerms(fromJSON: encoded) == ["release notes", "changelog"])
        #expect(SkillCatalog.decodeTerms(fromJSON: "not json") == [])
    }
}

// MARK: - O9: Peer approval gate

@Suite("PeerApprovalTests")
struct PeerApprovalTests {

    @Test func allowKeyFormat() {
        #expect(peerAllowKey(action: .askBot, targetBotId: "bot-7") == "ask_bot:bot-7")
        #expect(peerAllowKey(action: .delegateBot, targetBotId: "bot-7") == "delegate_bot:bot-7")
    }

    @Test func requestWithoutGrantRaisesCardThenResolves() {
        let coordinator = PeerApprovalCoordinator()
        guard case .pendingCard(let requestId) = coordinator.requestApproval(
            fromBotId: "research", toBotId: "comms", action: .askBot, message: "need numbers") else {
            Issue.record("expected a pending card")
            return
        }
        #expect(coordinator.pendingCount == 1)
        let outcome = coordinator.resolve(requestId: requestId, allow: true)
        #expect(outcome == .resolved(allowed: true))
        #expect(coordinator.pendingCount == 0)
        #expect(coordinator.resolve(requestId: requestId, allow: false) == .unknownRequest)
    }

    @Test func existingGrantAllowsImmediately() {
        let coordinator = PeerApprovalCoordinator()
        coordinator.addGrant(action: .delegateBot, targetBotId: "writer")
        let outcome = coordinator.requestApproval(
            fromBotId: "chief", toBotId: "writer", action: .delegateBot, message: "draft it")
        #expect(outcome == .allowedByExistingGrant)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func alwaysAllowRememberedOnResolveGrantsFutureAsks() {
        let coordinator = PeerApprovalCoordinator()
        guard case .pendingCard(let id) = coordinator.requestApproval(
            fromBotId: "a", toBotId: "b", action: .askBot, message: "hi") else {
            Issue.record("expected pending")
            return
        }
        _ = coordinator.resolve(requestId: id, allow: true, rememberGrant: true)
        #expect(coordinator.hasGrant(action: .askBot, targetBotId: "b"))

        let next = coordinator.requestApproval(fromBotId: "a", toBotId: "b", action: .askBot, message: "again")
        #expect(next == .allowedByExistingGrant)

        // A different target still needs its own approval.
        let other = coordinator.requestApproval(fromBotId: "a", toBotId: "c", action: .askBot, message: "hi c")
        #expect(other != .allowedByExistingGrant)
    }

    @Test func staleCardsAutoDeny() {
        let now = Date()
        let coordinator = PeerApprovalCoordinator()
        _ = coordinator.requestApproval(fromBotId: "a", toBotId: "b", action: .askBot,
                                        message: "old", now: now.addingTimeInterval(-3600))
        _ = coordinator.requestApproval(fromBotId: "a", toBotId: "c", action: .askBot,
                                        message: "fresh", now: now)

        let expired = coordinator.expireStale(now: now)
        #expect(expired.count == 1)
        #expect(expired.first?.toBotId == "b")
        #expect(coordinator.pendingCount == 1)
    }
}
