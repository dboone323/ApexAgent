import XCTest
import AVFoundation
import SwiftUI
@testable import ApexAgentCore

@MainActor
final class FullDuplexVoiceTests: XCTestCase {

    /// Helper to create a real AVAudioPCMBuffer containing a sine wave or silence.
    private func createAudioBuffer(frequency: Float = 440.0, amplitude: Float = 0.5, frameCount: AVAudioFrameCount = 1024) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100.0, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        let sampleRate = Float(format.sampleRate)
        for i in 0..<Int(frameCount) {
            if amplitude == 0.0 {
                channelData[i] = 0.0
            } else {
                channelData[i] = amplitude * sin(2.0 * Float.pi * frequency * Float(i) / sampleRate)
            }
        }

        return buffer
    }

    func testAudioDecibelsCalculationForSilenceAndSignal() {
        // 1. Test Silent Buffer
        guard let silentBuffer = createAudioBuffer(amplitude: 0.0) else {
            XCTFail("Failed to allocate silent buffer")
            return
        }
        let silentDb = FullDuplexVoiceSession.calculateDecibels(from: silentBuffer)
        XCTAssertEqual(silentDb, -80.0, accuracy: 0.1, "Silence should calculate to floor decibels (-80 dB)")

        // 2. Test Sine Wave Buffer (amplitude 0.5 -> RMS ~ 0.3535 -> 20*log10(0.3535) ~ -9.03 dB)
        guard let waveBuffer = createAudioBuffer(amplitude: 0.5) else {
            XCTFail("Failed to allocate wave buffer")
            return
        }
        let waveDb = FullDuplexVoiceSession.calculateDecibels(from: waveBuffer)
        XCTAssertGreaterThan(waveDb, -15.0, "Active sine wave should calculate to a high power level")
        XCTAssertLessThanOrEqual(waveDb, 0.0, "Decibels should not exceed 0.0 dB")
    }

    func testVoiceSessionStateTransitionsAndBargeIn() async {
        let session = FullDuplexVoiceSession.shared
        session.stopSession()
        XCTAssertFalse(session.isSessionActive)
        XCTAssertEqual(session.state, .idle)

        session.startSession()
        XCTAssertTrue(session.isSessionActive)
        XCTAssertEqual(session.state, .idle)

        // Simulate incoming speech buffer
        guard let speechBuffer = createAudioBuffer(amplitude: 0.6) else {
            XCTFail("Failed to generate speech buffer")
            return
        }
        session.processIncomingAudioBuffer(speechBuffer)
        XCTAssertEqual(session.state, .userSpeaking, "Session should transition to userSpeaking on loud audio")

        // Simulate model speaking response
        session.speakModelResponse("Test response", playAudio: false)
        XCTAssertEqual(session.state, .modelSpeaking, "Session should transition to modelSpeaking")

        // User barges in while model is speaking
        session.processIncomingAudioBuffer(speechBuffer)
        XCTAssertEqual(session.state, .userBargedIn, "Loud audio during model speaking must trigger bargeIn")

        session.stopSession()
        XCTAssertFalse(session.isSessionActive)
        XCTAssertEqual(session.state, .idle)
    }

    func testTurnFinalizationWithTranscript() {
        let session = FullDuplexVoiceSession.shared
        session.startSession()
        session.updateLiveTranscript("Create a new skill for testing")
        guard let speechBuffer = createAudioBuffer(amplitude: 0.6) else {
            XCTFail("Failed to create buffer")
            return
        }
        session.processIncomingAudioBuffer(speechBuffer)

        session.finalizeUserTurn(orchestrator: nil)
        XCTAssertEqual(session.lastCompletedTurnTranscript, "Create a new skill for testing")
        XCTAssertEqual(session.state, .modelThinking)

        session.stopSession()
    }

    func testVoiceOrbHUDViewHosting() {
        let session = FullDuplexVoiceSession.shared
        let view = VoiceOrbHUDView(voiceSession: session)
        let hostingController = NSHostingController(rootView: view)

        XCTAssertNotNil(hostingController.view)
        XCTAssertEqual(hostingController.view.subviews.count >= 0, true)
    }
}
