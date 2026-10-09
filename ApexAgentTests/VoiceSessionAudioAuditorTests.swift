import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 73 — Full Duplex Voice Session VAD & Audio Timing Gate Tests")
struct VoiceSessionAudioAuditorTests {

    @Test("calculateDecibels accurately calculates dBFS for silence vs sine wave")
    func calculateDecibelsAccurate() {
        // Pure silence (all zeros)
        let silence = [Float](repeating: 0.0, count: 320)
        let silenceDbfs = VoiceSessionAudioAuditor.calculateDecibels(samples: silence)
        #expect(silenceDbfs == -80.0)

        // 1 kHz sine wave at amplitude 0.5 (RMS should be ~0.5 / sqrt(2) = 0.3535, dBFS ~ -9.03 dB)
        var sineWave = [Float](repeating: 0.0, count: 160)
        for i in 0..<160 {
            let t = Double(i) / 16000.0
            sineWave[i] = Float(0.5 * sin(2.0 * .pi * 1000.0 * t))
        }
        let sineDbfs = VoiceSessionAudioAuditor.calculateDecibels(samples: sineWave)
        #expect(sineDbfs > -10.0 && sineDbfs < -8.0)
    }

    @Test("Clean audio packet stream with speech and turn completion passes audit")
    func cleanAudioStreamPasses() {
        var packets: [AudioStreamPacket] = []
        let sampleRate = 16000.0
        let frameSize = 320 // 20ms per packet
        let frameDuration = Double(frameSize) / sampleRate

        // 5 quiet frames, 10 speech frames, 70 silent frames (1.4s of silence > 1.2s threshold)
        for i in 0..<85 {
            let timestamp = Double(i) * frameDuration
            let samples: [Float]
            if i >= 5 && i < 15 {
                // Speech frame (-20 dBFS amplitude ~0.1)
                samples = (0..<frameSize).map { _ in Float.random(in: -0.15...0.15) }
            } else {
                // Background noise (-60 dBFS)
                samples = (0..<frameSize).map { _ in Float.random(in: -0.001...0.001) }
            }

            packets.append(AudioStreamPacket(
                sequenceNumber: UInt64(i + 1),
                timestampSeconds: timestamp,
                sampleRate: sampleRate,
                samples: samples
            ))
        }

        let report = VoiceSessionAudioAuditor.auditStream(packets: packets)
        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.sampleRateValid)
        #expect(report.sequencingValid)
        #expect(report.jitterWithinBounds)
        #expect(report.vadEvaluation.detectedSpeechStartsCount == 1)
        #expect(report.vadEvaluation.detectedTurnCompletionsCount == 1)
        #expect(!report.vadEvaluation.bargeInTriggered)
    }

    @Test("Barge-in is detected when user speaks loudly while model is speaking")
    func bargeInDetection() {
        let sampleRate = 24000.0
        let frameSize = 480
        var packets: [AudioStreamPacket] = []

        for i in 0..<10 {
            // High energy audio exceeding barge-in threshold (-30 dBFS)
            let loudSamples = (0..<frameSize).map { _ in Float.random(in: -0.4...0.4) }
            packets.append(AudioStreamPacket(
                sequenceNumber: UInt64(i + 1),
                timestampSeconds: Double(i) * 0.02,
                sampleRate: sampleRate,
                samples: loudSamples
            ))
        }

        let report = VoiceSessionAudioAuditor.auditStream(packets: packets, isModelSpeaking: true)
        #expect(report.vadEvaluation.bargeInTriggered)
    }

    @Test("Sequence gap or unsupported sample rate triggers audit violations")
    func sequenceGapAndUnsupportedSampleRateTriggerViolations() {
        let p1 = AudioStreamPacket(sequenceNumber: 1, timestampSeconds: 0.0, sampleRate: 16000.0, samples: [0.0])
        // Sequence gap from 1 to 5 and unsupported sample rate 8000 Hz
        let p2 = AudioStreamPacket(sequenceNumber: 5, timestampSeconds: 0.02, sampleRate: 8000.0, samples: [0.0])

        let report = VoiceSessionAudioAuditor.auditStream(packets: [p1, p2])
        #expect(!report.passed)
        #expect(!report.sequencingValid)
        #expect(!report.sampleRateValid)
        #expect(report.violations.contains { $0.code == "PACKET_SEQUENCE_GAP" })
        #expect(report.violations.contains { $0.code == "UNSUPPORTED_SAMPLE_RATE" })
    }
}
