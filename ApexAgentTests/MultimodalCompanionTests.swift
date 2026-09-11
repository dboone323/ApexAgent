import XCTest
import AVFoundation
@testable import ApexAgentCore

@MainActor
final class MultimodalCompanionTests: XCTestCase {

    func testGlobalCommandPaletteShowHide() {
        let controller = GlobalCommandPaletteController.shared
        controller.show()
        XCTAssertTrue(controller.isVisible)
        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }
    
    func testGlobalCommandPaletteToggle() {
        let controller = GlobalCommandPaletteController.shared
        let initial = controller.isVisible
        controller.toggle()
        XCTAssertNotEqual(controller.isVisible, initial)
        controller.toggle()
        XCTAssertEqual(controller.isVisible, initial)
    }
    
    func testGhostCursorShowAndHide() {
        let ghost = GhostCursorController.shared
        ghost.showCursor(at: CGPoint(x: 100, y: 100))
        XCTAssertTrue(ghost.isVisible)
        XCTAssertEqual(ghost.cursorPosition, CGPoint(x: 100, y: 100))
        ghost.hideCursor()
        XCTAssertFalse(ghost.isVisible)
    }
    
    func testGhostCursorAnimateClick() async throws {
        let ghost = GhostCursorController.shared
        ghost.showCursor(at: CGPoint(x: 200, y: 200))
        ghost.animateClick()
        XCTAssertTrue(ghost.isClicking)
        
        // Wait up to 1.5s for click animation to complete on overloaded CI / test runners
        var waited: TimeInterval = 0
        while ghost.isClicking && waited < 1.5 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        XCTAssertFalse(ghost.isClicking)
    }
    
    func testFullDuplexVoiceSessionBargeInInitialState() {
        let session = FullDuplexVoiceSession()
        XCTAssertFalse(session.bargeInDetected)
        XCTAssertFalse(session.isSpeaking)
        XCTAssertEqual(session.state, .idle)
    }

    func testAudioBufferDecibelComputation() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024) else {
            XCTFail("Could not create real AVAudioPCMBuffer")
            return
        }
        buffer.frameLength = 1024
        
        // 1. Test pure silence buffer
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<1024 {
                channelData[i] = 0.0
            }
        }
        let silenceDb = FullDuplexVoiceSession.calculateDecibels(from: buffer)
        XCTAssertEqual(silenceDb, -80.0, "Pure silence must return -80.0 dB")
        
        // 2. Test full amplitude sine wave (0 dB)
        if let channelData = buffer.floatChannelData?[0] {
            for i in 0..<1024 {
                channelData[i] = sin(Float(i) * 2.0 * .pi * 440.0 / 44100.0)
            }
        }
        let sineDb = FullDuplexVoiceSession.calculateDecibels(from: buffer)
        XCTAssertGreaterThan(sineDb, -10.0, "Full amplitude sine wave must calculate high decibels (near -3dB)")
        XCTAssertLessThanOrEqual(sineDb, 0.0, "Decibels must not exceed 0 dB")
    }

    func testFullDuplexVoiceSessionBargeInFlow() {
        let session = FullDuplexVoiceSession()
        session.startSession()
        XCTAssertTrue(session.isSessionActive)
        
        // Simulate model speaking response
        session.speakModelResponse("Hello user", playAudio: false)
        XCTAssertEqual(session.state, .modelSpeaking)
        
        // Simulate user barge-in interruption
        session.handleBargeIn()
        XCTAssertEqual(session.state, .userBargedIn)
        XCTAssertTrue(session.bargeInDetected)
        XCTAssertFalse(session.isSpeaking)
        
        session.stopSession()
        XCTAssertFalse(session.isSessionActive)
        XCTAssertEqual(session.state, .idle)
    }

    func testRemoteCompanionApprovalRelayWithCapabilityToken() {
        let gateway = RemoteCompanionGateway.shared
        let toolName = "destructive_remote_tool_\(Int.random(in: 1000...9999))"
        let event = CompanionApprovalRelayEvent(
            requestId: UUID().uuidString,
            stageId: "stage_001",
            stageName: toolName,
            summary: "Delete critical file",
            riskLevel: "high"
        )
        
        gateway.postApprovalRelay(event)
        XCTAssertNotNil(gateway.pendingApprovalRelays[event.requestId])
        
        // Resolve approval as allowed
        let resolved = gateway.resolveApprovalRelay(requestId: event.requestId, allow: true)
        XCTAssertEqual(resolved?.requestId, event.requestId)
        XCTAssertNil(gateway.pendingApprovalRelays[event.requestId])
        
        // Verify EphemeralCapability token was issued
        XCTAssertTrue(
            EphemeralCapabilityManager.shared.hasValidToken(botName: nil, toolName: toolName),
            "Approved companion relay must issue an ephemeral capability token"
        )
        
        // Cleanup
        EphemeralCapabilityManager.shared.revokeAll(for: toolName)
    }

    func testGhostCursorInactivityFade() async throws {
        let ghost = GhostCursorController.shared
        ghost.showCursor(at: CGPoint(x: 150, y: 150))
        XCTAssertTrue(ghost.isVisible)
        
        // Wait 2.1s for inactivity auto-hide
        try await Task.sleep(nanoseconds: 2_100_000_000)
        XCTAssertFalse(ghost.isVisible, "Ghost cursor should automatically fade out after 2 seconds of inactivity")
    }

    func testRemoteCompanionSensorUploadFlow() {
        let gateway = RemoteCompanionGateway.shared
        let client = ApexCompanionMobileClient()
        
        let paired = client.pair(with: gateway, sharedSecret: "ApexCompanionSecretKey")
        XCTAssertTrue(paired, "Client must pair with gateway using valid shared secret")
        
        let uploaded = client.uploadSensorPayload(
            to: gateway,
            kind: .cameraPhoto,
            dataBase64: "aGVsbG9fd29ybGQ=",
            metadata: ["resolution": "1920x1080"]
        )
        XCTAssertTrue(uploaded, "Camera sensor frame must upload successfully to paired host gateway")
        XCTAssertFalse(gateway.receivedSensorUploads.isEmpty)
        XCTAssertEqual(gateway.receivedSensorUploads.last?.kind, .cameraPhoto)
        
        client.unpair()
        XCTAssertFalse(client.isPaired)
    }
}
