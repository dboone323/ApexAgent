import Foundation
import Accelerate

// MARK: - Voice Session Audio & VAD Timing Gate (Batch 73)

/// Configuration policy for voice session audio auditing.
public struct AudioSessionConfig: Sendable, Codable, Equatable {
    /// Speech onset threshold in dBFS (e.g. -38.0 dBFS).
    public var speechThresholdDbfs: Float
    /// Barge-in interruption threshold in dBFS (e.g. -30.0 dBFS).
    public var bargeInThresholdDbfs: Float
    /// Silence duration in seconds required to close a speech turn (e.g. 1.2s).
    public var silenceDurationForTurnSeconds: TimeInterval
    /// Minimum consecutive speech frames required to trigger voice detection.
    public var minSpeechOnsetFrames: Int
    /// Supported sample rates (e.g., 16000, 24000, 48000 Hz).
    public var supportedSampleRates: [Double]
    /// Maximum allowable audio stream jitter/drift in milliseconds.
    public var maxJitterToleranceMs: Double

    public init(
        speechThresholdDbfs: Float = -38.0,
        bargeInThresholdDbfs: Float = -30.0,
        silenceDurationForTurnSeconds: TimeInterval = 1.2,
        minSpeechOnsetFrames: Int = 3,
        supportedSampleRates: [Double] = [16000.0, 24000.0, 48000.0],
        maxJitterToleranceMs: Double = 150.0
    ) {
        self.speechThresholdDbfs = speechThresholdDbfs
        self.bargeInThresholdDbfs = bargeInThresholdDbfs
        self.silenceDurationForTurnSeconds = silenceDurationForTurnSeconds
        self.minSpeechOnsetFrames = minSpeechOnsetFrames
        self.supportedSampleRates = supportedSampleRates
        self.maxJitterToleranceMs = maxJitterToleranceMs
    }
}

/// Single packet in an audio streaming session.
public struct AudioStreamPacket: Sendable, Equatable {
    public let sequenceNumber: UInt64
    public let timestampSeconds: TimeInterval
    public let sampleRate: Double
    public let channelCount: Int
    public let samples: [Float]

    public init(
        sequenceNumber: UInt64,
        timestampSeconds: TimeInterval,
        sampleRate: Double,
        channelCount: Int = 1,
        samples: [Float]
    ) {
        self.sequenceNumber = sequenceNumber
        self.timestampSeconds = timestampSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.samples = samples
    }
}

/// Audit violation recorded during voice session analysis.
public struct AudioAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let packetIndex: Int?

    public init(code: String, message: String, packetIndex: Int? = nil) {
        self.code = code
        self.message = message
        self.packetIndex = packetIndex
    }
}

/// Result of evaluating VAD behavior across audio frames.
public struct VADEvaluationResult: Sendable, Codable, Equatable {
    public let totalFrames: Int
    public let speechFramesCount: Int
    public let detectedSpeechStartsCount: Int
    public let detectedTurnCompletionsCount: Int
    public let bargeInTriggered: Bool
    public let averageSpeechEnergyDbfs: Float
}

/// Complete report of audio session health and VAD compliance.
public struct VoiceSessionAudioAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let evaluatedPacketsCount: Int
    public let sampleRateValid: Bool
    public let sequencingValid: Bool
    public let jitterWithinBounds: Bool
    public let vadEvaluation: VADEvaluationResult
    public let violations: [AudioAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        evaluatedPacketsCount: Int,
        sampleRateValid: Bool,
        sequencingValid: Bool,
        jitterWithinBounds: Bool,
        vadEvaluation: VADEvaluationResult,
        violations: [AudioAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.evaluatedPacketsCount = evaluatedPacketsCount
        self.sampleRateValid = sampleRateValid
        self.sequencingValid = sequencingValid
        self.jitterWithinBounds = jitterWithinBounds
        self.vadEvaluation = vadEvaluation
        self.violations = violations
    }
}

/// Production auditor for voice stream timing, decibels, and VAD state machines.
public enum VoiceSessionAudioAuditor {

    // MARK: - RMS & Decibel Calculation

    /// Computes normalized root-mean-square decibels relative to full scale (dBFS) for 32-bit float samples.
    public static func calculateDecibels(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -80.0 }

        var sumSquare: Float = 0.0
        for sample in samples {
            sumSquare += sample * sample
        }
        let rms = sqrt(sumSquare / Float(samples.count))
        if rms <= 0.0001 {
            return -80.0
        }
        let dbfs = 20.0 * log10(rms)
        return max(-80.0, min(0.0, dbfs))
    }

    // MARK: - Stream Audit

    /// Audits an array of incoming audio packets for sample rate adherence, sequence continuity, jitter, and VAD accuracy.
    public static func auditStream(
        packets: [AudioStreamPacket],
        config: AudioSessionConfig = AudioSessionConfig(),
        isModelSpeaking: Bool = false
    ) -> VoiceSessionAudioAuditReport {
        var violations: [AudioAuditViolation] = []
        var sampleRateValid = true
        var sequencingValid = true
        var jitterWithinBounds = true

        guard !packets.isEmpty else {
            violations.append(AudioAuditViolation(code: "EMPTY_AUDIO_STREAM", message: "Audio packet stream contains zero packets."))
            let vad = VADEvaluationResult(
                totalFrames: 0,
                speechFramesCount: 0,
                detectedSpeechStartsCount: 0,
                detectedTurnCompletionsCount: 0,
                bargeInTriggered: false,
                averageSpeechEnergyDbfs: -80.0
            )
            return VoiceSessionAudioAuditReport(
                passed: false,
                score: 0.0,
                evaluatedPacketsCount: 0,
                sampleRateValid: false,
                sequencingValid: false,
                jitterWithinBounds: false,
                vadEvaluation: vad,
                violations: violations
            )
        }

        var energies: [Float] = []
        var timestamps: [TimeInterval] = []

        for (idx, packet) in packets.enumerated() {
            // 1. Sample rate check
            if !config.supportedSampleRates.contains(packet.sampleRate) {
                sampleRateValid = false
                violations.append(AudioAuditViolation(
                    code: "UNSUPPORTED_SAMPLE_RATE",
                    message: "Packet \(idx) uses unsupported sample rate: \(packet.sampleRate) Hz.",
                    packetIndex: idx
                ))
            }

            // 2. Sequence continuity
            if idx > 0 {
                let prevPacket = packets[idx - 1]
                if packet.sequenceNumber != prevPacket.sequenceNumber + 1 {
                    sequencingValid = false
                    violations.append(AudioAuditViolation(
                        code: "PACKET_SEQUENCE_GAP",
                        message: "Sequence jump from \(prevPacket.sequenceNumber) to \(packet.sequenceNumber).",
                        packetIndex: idx
                    ))
                }

                // Jitter drift check
                let deltaSec = packet.timestampSeconds - prevPacket.timestampSeconds
                let expectedIntervalSec = Double(prevPacket.samples.count) / prevPacket.sampleRate
                let jitterMs = abs(deltaSec - expectedIntervalSec) * 1000.0
                if jitterMs > config.maxJitterToleranceMs {
                    jitterWithinBounds = false
                    violations.append(AudioAuditViolation(
                        code: "JITTER_TOLERANCE_EXCEEDED",
                        message: "Jitter of \(String(format: "%.1f", jitterMs))ms exceeds tolerance of \(config.maxJitterToleranceMs)ms.",
                        packetIndex: idx
                    ))
                }
            }

            let energy = calculateDecibels(samples: packet.samples)
            energies.append(energy)
            timestamps.append(packet.timestampSeconds)
        }

        let vad = evaluateVAD(
            frameEnergies: energies,
            timestamps: timestamps,
            config: config,
            isModelSpeaking: isModelSpeaking
        )

        let passed = violations.isEmpty
        let score = passed ? 100.0 : max(0.0, 100.0 - Double(violations.count) * 25.0)

        return VoiceSessionAudioAuditReport(
            passed: passed,
            score: score,
            evaluatedPacketsCount: packets.count,
            sampleRateValid: sampleRateValid,
            sequencingValid: sequencingValid,
            jitterWithinBounds: jitterWithinBounds,
            vadEvaluation: vad,
            violations: violations
        )
    }

    // MARK: - VAD Evaluation

    /// Evaluates voice activity transitions (speech onset, silence completion, barge-in).
    public static func evaluateVAD(
        frameEnergies: [Float],
        timestamps: [TimeInterval],
        config: AudioSessionConfig = AudioSessionConfig(),
        isModelSpeaking: Bool = false
    ) -> VADEvaluationResult {
        guard !frameEnergies.isEmpty else {
            return VADEvaluationResult(
                totalFrames: 0,
                speechFramesCount: 0,
                detectedSpeechStartsCount: 0,
                detectedTurnCompletionsCount: 0,
                bargeInTriggered: false,
                averageSpeechEnergyDbfs: -80.0
            )
        }

        var speechFramesCount = 0
        var consecutiveSpeechFrames = 0
        var consecutiveSilenceDuration: TimeInterval = 0.0
        var speechStarts = 0
        var turnCompletions = 0
        var inSpeechState = false
        var bargeIn = false
        var speechEnergySum: Float = 0.0

        for idx in 0..<frameEnergies.count {
            let energy = frameEnergies[idx]
            let dt: TimeInterval = idx > 0 ? (timestamps[idx] - timestamps[idx - 1]) : 0.02

            if energy >= config.speechThresholdDbfs {
                speechFramesCount += 1
                speechEnergySum += energy
                consecutiveSpeechFrames += 1
                consecutiveSilenceDuration = 0.0

                if isModelSpeaking && energy >= config.bargeInThresholdDbfs {
                    bargeIn = true
                }

                if !inSpeechState && consecutiveSpeechFrames >= config.minSpeechOnsetFrames {
                    inSpeechState = true
                    speechStarts += 1
                }
            } else {
                consecutiveSpeechFrames = 0
                if inSpeechState {
                    consecutiveSilenceDuration += dt
                    if consecutiveSilenceDuration >= config.silenceDurationForTurnSeconds {
                        inSpeechState = false
                        turnCompletions += 1
                        consecutiveSilenceDuration = 0.0
                    }
                }
            }
        }

        let avgEnergy = speechFramesCount > 0 ? (speechEnergySum / Float(speechFramesCount)) : -80.0

        return VADEvaluationResult(
            totalFrames: frameEnergies.count,
            speechFramesCount: speechFramesCount,
            detectedSpeechStartsCount: speechStarts,
            detectedTurnCompletionsCount: turnCompletions,
            bargeInTriggered: bargeIn,
            averageSpeechEnergyDbfs: avgEnergy
        )
    }
}
