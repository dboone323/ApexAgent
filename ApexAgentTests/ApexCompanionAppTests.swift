import XCTest
import SwiftUI
@testable import ApexAgentCore

@MainActor
final class ApexCompanionAppTests: XCTestCase {

    func testCompanionMessageFrameEncodingAndDecoding() throws {
        let frame = CompanionMessageFrame(
            type: .hello,
            senderId: "iphone_dan_15_pro_max",
            sessionToken: "Token12345",
            payloadJSON: "{\"deviceId\": \"iphone_dan_15_pro_max\"}"
        )

        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(CompanionMessageFrame.self, from: data)

        XCTAssertEqual(decoded.type, .hello)
        XCTAssertEqual(decoded.senderId, "iphone_dan_15_pro_max")
        XCTAssertEqual(decoded.sessionToken, "Token12345")
        XCTAssertTrue(decoded.payloadJSON.contains("iphone_dan_15_pro_max"))
    }

    func testCompanionCameraSensorPhotoEncodingAndGatewayIngestion() {
        let sensor = CompanionCameraSensor()
        let fakeImageData = "FAKE_JPEG_IMAGE_PIXELS_DATA_12345".data(using: .utf8)!

        let payload = sensor.encodePhotoPayload(jpegData: fakeImageData, sourceDevice: "Dan's iPhone 15 Pro Max")
        XCTAssertEqual(payload.kind, CompanionSensorPayload.SensorKind.cameraPhoto)
        XCTAssertEqual(payload.metadata["device"], "Dan's iPhone 15 Pro Max")
        XCTAssertEqual(payload.metadata["format"], "jpeg")
        XCTAssertFalse(payload.dataBase64.isEmpty)

        // Gateway Ingestion test
        let gateway = RemoteCompanionGateway()
        gateway.configure(sharedSecret: "SensorSecretKey")

        let client = ApexCompanionMobileClient()
        _ = client.pair(with: gateway, sharedSecret: "SensorSecretKey")

        let uploaded = client.uploadSensorPayload(
            to: gateway,
            kind: .cameraPhoto,
            dataBase64: payload.dataBase64,
            metadata: payload.metadata
        )
        XCTAssertTrue(uploaded)
        XCTAssertEqual(gateway.receivedSensorUploads.count, 1)
        XCTAssertEqual(gateway.receivedSensorUploads.first?.kind, CompanionSensorPayload.SensorKind.cameraPhoto)
    }

    func testCompanionLocationSensorPayload() {
        let sensor = CompanionCameraSensor()
        let payload = sensor.encodeLocationPayload(latitude: 37.7749, longitude: -122.4194, accuracyMeters: 5.0)

        XCTAssertEqual(payload.kind, CompanionSensorPayload.SensorKind.location)
        XCTAssertEqual(payload.metadata["latitude"], "37.7749")
        XCTAssertEqual(payload.metadata["longitude"], "-122.4194")
        XCTAssertEqual(payload.metadata["accuracy"], "5.0")
    }

    func testCompanionViewsConstruction() {
        let event = CompanionApprovalRelayEvent(
            requestId: "req_test_card",
            stageId: "stage_test",
            stageName: "Deploy Container Gate",
            summary: "Deploying latest commit to ephemeral container sandbox",
            riskLevel: "high"
        )

        var decisionOutcome: Bool?
        let cardView = CompanionApprovalCardView(event: event) { approved, _ in
            decisionOutcome = approved
        }
        _ = cardView

        let voiceView = CompanionVoiceOrbView(isSpeaking: true, decibelLevel: -15.0)
        _ = voiceView

        let gateway = RemoteCompanionGateway()
        let client = ApexCompanionMobileClient()
        let mainView = CompanionMainView(client: client, gateway: gateway)
        _ = mainView

        XCTAssertNil(decisionOutcome)
    }

    func testFullCompanionWorkflowWithoutDiscord() {
        let gateway = RemoteCompanionGateway()
        gateway.configure(sharedSecret: "NoDiscordKey")

        let client = ApexCompanionMobileClient(
            deviceId: "iphone_dan_15_pro_max",
            deviceName: "Dan's iPhone 15 Pro Max"
        )

        // 1. Pair directly over Bonjour
        let paired = client.pair(with: gateway, sharedSecret: "NoDiscordKey")
        XCTAssertTrue(paired)

        // 2. Mac host raises approval gate
        let event = CompanionApprovalRelayEvent(
            requestId: "req_pr_merge_42",
            stageId: "stage_pr_review",
            stageName: "Merge Pull Request #42",
            summary: "All 47 unit tests green; ready to merge to main branch",
            riskLevel: "medium"
        )
        gateway.postApprovalRelay(event)
        XCTAssertEqual(gateway.pendingApprovalRelays.count, 1)

        // 3. iPhone Companion receives pending approval card
        let approvals = client.fetchPendingApprovals(from: gateway)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.requestId, "req_pr_merge_42")

        // 4. User taps "Approve" on iPhone 15 Pro Max
        let resolved = client.submitDecision(on: gateway, requestId: "req_pr_merge_42", allow: true, notes: "Approved on iPhone")
        XCTAssertTrue(resolved)
        XCTAssertEqual(gateway.pendingApprovalRelays.count, 0)
    }
}
