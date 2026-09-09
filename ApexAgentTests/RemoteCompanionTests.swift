import XCTest
@testable import ApexAgentCore

@MainActor
final class RemoteCompanionTests: XCTestCase {

    func testBonjourServiceDescriptorConfiguration() {
        let gateway = RemoteCompanionGateway()
        let descriptor = gateway.makeBonjourServiceDescriptor()

        XCTAssertEqual(descriptor.type, "_apexagent._tcp")
        XCTAssertEqual(descriptor.domain, "local.")
        XCTAssertEqual(descriptor.txtRecord["version"], "1.0")
        XCTAssertTrue(descriptor.txtRecord["capabilities"]?.contains("approvals") ?? false)
        XCTAssertTrue(descriptor.txtRecord["capabilities"]?.contains("live_activities") ?? false)
        XCTAssertNotNil(descriptor.txtRecord["hostId"])
    }

    func testCompanionPairingHandshakeSuccessAndFailure() {
        let gateway = RemoteCompanionGateway()
        gateway.configure(sharedSecret: "TestSecret12345")

        let request = CompanionPairingRequest(
            deviceId: "iphone_dan_15_pro_max_test",
            deviceName: "Dan's iPhone 15 Pro Max",
            clientChallenge: "ChallengeNonceABC"
        )

        // 1. Handshake with incorrect secret -> Rejected
        let rejectedAck = gateway.processPairingRequest(request, sharedSecretProvided: "WrongSecret")
        XCTAssertFalse(rejectedAck.isAuthorized)
        XCTAssertTrue(rejectedAck.sessionToken.isEmpty)
        XCTAssertNil(gateway.pairedDevices[request.deviceId])

        // 2. Handshake with correct secret -> Authorized
        let successAck = gateway.processPairingRequest(request, sharedSecretProvided: "TestSecret12345")
        XCTAssertTrue(successAck.isAuthorized)
        XCTAssertFalse(successAck.sessionToken.isEmpty)
        XCTAssertNotNil(gateway.pairedDevices[request.deviceId])
        XCTAssertEqual(gateway.pairedDevices[request.deviceId]?.name, "Dan's iPhone 15 Pro Max")
    }

    func testApprovalCardRelayWorkflow() {
        let gateway = RemoteCompanionGateway()

        let event = CompanionApprovalRelayEvent(
            requestId: "req_approval_999",
            stageId: "stage_merge_gate",
            stageName: "Merge Approval Gate",
            summary: "Merge branch feature/companion to main",
            riskLevel: "high"
        )

        gateway.postApprovalRelay(event)
        XCTAssertEqual(gateway.pendingApprovalRelays.count, 1)
        XCTAssertEqual(gateway.pendingApprovalRelays["req_approval_999"]?.stageName, "Merge Approval Gate")

        let resolved = gateway.resolveApprovalRelay(requestId: "req_approval_999", allow: true)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.requestId, "req_approval_999")
        XCTAssertEqual(gateway.pendingApprovalRelays.count, 0)
    }

    func testApexCompanionMobileClientIPhone15ProMaxWorkflow() {
        let gateway = RemoteCompanionGateway()
        gateway.configure(sharedSecret: "SecureKeyIPhone15")

        let client = ApexCompanionMobileClient(
            deviceId: "iphone_dan_15_pro_max",
            deviceName: "Dan's iPhone 15 Pro Max",
            hardwareModel: "iPhone16,2"
        )

        XCTAssertEqual(client.deviceName, "Dan's iPhone 15 Pro Max")
        XCTAssertEqual(client.hardwareModel, "iPhone16,2")
        XCTAssertFalse(client.isPaired)

        // 1. Pair with correct secret
        let paired = client.pair(with: gateway, sharedSecret: "SecureKeyIPhone15")
        XCTAssertTrue(paired)
        XCTAssertTrue(client.isPaired)
        XCTAssertNotNil(client.activeSessionToken)
        XCTAssertNotNil(client.connectedHostName)

        // 2. Post an approval card on the gateway
        let event = CompanionApprovalRelayEvent(
            requestId: "req_stage_deploy_01",
            stageId: "stage_deploy_prod",
            stageName: "Deploy to Production",
            summary: "Push release build to staging container",
            riskLevel: "high"
        )
        gateway.postApprovalRelay(event)

        // 3. Client fetches pending approvals
        let pending = client.fetchPendingApprovals(from: gateway)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.stageName, "Deploy to Production")

        // 4. Client submits approval decision
        let decisionSuccess = client.submitDecision(
            on: gateway,
            requestId: "req_stage_deploy_01",
            allow: true,
            notes: "Approved from Dan's iPhone 15 Pro Max"
        )
        XCTAssertTrue(decisionSuccess)
        XCTAssertEqual(gateway.pendingApprovalRelays.count, 0)

        // 5. Unpair
        client.unpair()
        XCTAssertFalse(client.isPaired)
        XCTAssertNil(client.activeSessionToken)
    }

    func testCompanionLiveActivityStateDispatchAndSync() {
        let gateway = RemoteCompanionGateway()
        gateway.configure(sharedSecret: "LiveActivityKey")

        let client = ApexCompanionMobileClient(
            deviceId: "iphone_dan_15_pro_max",
            deviceName: "Dan's iPhone 15 Pro Max",
            hardwareModel: "iPhone16,2"
        )
        _ = client.pair(with: gateway, sharedSecret: "LiveActivityKey")

        let liveState = CompanionLiveActivityState(
            playbookTitle: "Full PR Review Loop",
            currentStageTitle: "Security & Lint Audit",
            activeBotName: "Auditor",
            progressFraction: 0.65,
            pendingApprovalCount: 1,
            isRunning: true
        )

        gateway.updateLiveActivity(liveState)
        XCTAssertEqual(gateway.currentLiveActivity?.playbookTitle, "Full PR Review Loop")

        client.syncLiveActivity(from: gateway)
        XCTAssertEqual(client.liveActivityState?.currentStageTitle, "Security & Lint Audit")
        XCTAssertEqual(client.liveActivityState?.progressFraction, 0.65)
        XCTAssertEqual(client.liveActivityState?.activeBotName, "Auditor")
    }

    func testAdvertisingLifecycle() {
        let gateway = RemoteCompanionGateway()
        gateway.stopAdvertising()
        XCTAssertFalse(gateway.isAdvertising)

        gateway.startAdvertising()
        XCTAssertTrue(gateway.isAdvertising)

        gateway.stopAdvertising()
        XCTAssertFalse(gateway.isAdvertising)
    }
}
