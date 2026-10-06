import Foundation
import AVFoundation
import Speech
import SwiftUI

// MARK: - Voice Activity State

public enum VoiceActivityState: String, Sendable, Equatable {
    case idle = "idle"
    case userSpeaking = "listening"
    case modelThinking = "thinking"
    case modelSpeaking = "speaking"
    case userBargedIn = "interrupted"
}

// MARK: - FullDuplexVoiceSession

@MainActor
public final class FullDuplexVoiceSession: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    public static let shared = FullDuplexVoiceSession()

    @Published public private(set) var state: VoiceActivityState = .idle
    @Published public private(set) var isSessionActive: Bool = false
    @Published public private(set) var currentDecibels: Float = -80.0
    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var lastCompletedTurnTranscript: String?

    @Published public var isSpeaking: Bool = false
    @Published public var bargeInDetected: Bool = false
    public var bargeInSilenceThreshold: Float = -30.0
    private var bargeInMonitoringTask: Task<Void, Never>?
    private let audioEngine = AVAudioEngine()

    private let speechSynthesizer = AVSpeechSynthesizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    // Audio Power & VAD Constants
    public var speechThresholdDb: Float = -38.0
    public var silenceDurationForTurnSeconds: TimeInterval = 1.2

    private var silenceTimerTask: Task<Void, Never>?
    private var consecutiveSilenceFrames: Int = 0

    public override init() {
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.speechSynthesizer.delegate = self
    }

    // MARK: - Audio Power Calculation

    /// Calculates normalized root-mean-square (RMS) decibels from an audio PCM buffer.
    public nonisolated static func calculateDecibels(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0] else { return -80.0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return -80.0 }

        var sum: Float = 0.0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        if rms <= 0.00001 { return -80.0 }
        let db = 20.0 * log10(rms)
        return max(-80.0, min(0.0, db))
    }

    // MARK: - Session Control

    public func startSession(orchestrator: AgentOrchestrator? = nil) {
        guard !isSessionActive else { return }
        isSessionActive = true
        state = .idle
        liveTranscript = ""
    }

    public func stopSession() {
        isSessionActive = false
        stopSynthesis()
        cancelRecognition()
        silenceTimerTask?.cancel()
        silenceTimerTask = nil
        state = .idle
        currentDecibels = -80.0
    }

    // MARK: - Process Audio Input

    /// Feed audio buffer from input node, evaluate VAD, compute decibels, and handle barge-in.
    public func processIncomingAudioBuffer(_ buffer: AVAudioPCMBuffer, orchestrator: AgentOrchestrator? = nil) {
        guard isSessionActive else { return }

        let db = Self.calculateDecibels(from: buffer)
        self.currentDecibels = db

        let isSpeechDetected = db > speechThresholdDb

        if isSpeechDetected {
            silenceTimerTask?.cancel()
            silenceTimerTask = nil
            consecutiveSilenceFrames = 0

            // Check for Barge-in / Interruption
            if state == .modelSpeaking || state == .modelThinking {
                handleBargeIn()
            } else if state != .userSpeaking && state != .userBargedIn {
                state = .userSpeaking
            }
        } else {
            if state == .userSpeaking {
                consecutiveSilenceFrames += 1
                if silenceTimerTask == nil {
                    scheduleTurnFinalization(orchestrator: orchestrator)
                }
            }
        }
    }

    // MARK: - Barge-in & Turn-Taking

    public func handleBargeIn(orchestrator: AgentOrchestrator? = nil) {
        state = .userBargedIn
        stopSynthesis()
        bargeInDetected = true
        isSpeaking = false
        orchestrator?.cancelGeneration()
    }

    public func startMonitoringForBargeIn() {
        guard !audioEngine.isRunning else { return }
        bargeInDetected = false
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        
        do {
            try inputNode.installAudioTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self = self else { return }
                let pcmBuffer = AVAudioPCMBuffer(copying: buffer)
                let db = Self.calculateDecibels(from: pcmBuffer)

                // This is called on a background thread.
                // We just let the tap run, but the task will sample it.
                Task { @MainActor in
                    self.currentDecibels = db
                }
            }
        } catch {
            print("Failed to install audio tap: \(error)")
        }
        
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("Failed to start engine: \(error)")
            return
        }
        
        bargeInMonitoringTask = Task { @MainActor in
            var consecutiveHits = 0
            while !Task.isCancelled && self.isSpeaking {
                if self.currentDecibels > self.bargeInSilenceThreshold {
                    consecutiveHits += 1
                } else {
                    consecutiveHits = 0
                }
                
                if consecutiveHits >= 3 {
                    self.handleBargeIn()
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    public func stopMonitoringForBargeIn() {
        bargeInMonitoringTask?.cancel()
        bargeInMonitoringTask = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    private func scheduleTurnFinalization(orchestrator: AgentOrchestrator?) {
        silenceTimerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.silenceDurationForTurnSeconds ?? 1.2) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finalizeUserTurn(orchestrator: orchestrator)
        }
    }

    public func finalizeUserTurn(orchestrator: AgentOrchestrator?) {
        guard state == .userSpeaking || state == .userBargedIn else { return }
        let transcript = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            state = .idle
            return
        }

        lastCompletedTurnTranscript = transcript
        liveTranscript = ""
        state = .modelThinking

        if let orch = orchestrator {
            orch.sendMessage(transcript)
        }
    }

    public func updateLiveTranscript(_ text: String) {
        self.liveTranscript = text
    }

    // MARK: - Speech Synthesis

    public func speakModelResponse(_ text: String, playAudio: Bool = true) {
        guard isSessionActive else { return }
        stopSynthesis()
        state = .modelSpeaking

        if playAudio {
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            isSpeaking = true
            startMonitoringForBargeIn()
            speechSynthesizer.speak(utterance)
        }
    }

    public func stopSynthesis() {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .word)
        }
    }

    private func cancelRecognition() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.state == .modelSpeaking {
                self.state = .idle
            }
            self.isSpeaking = false
            self.stopMonitoringForBargeIn()
        }
    }

    // MARK: - Markdown Session Diagnostics

    public func sessionSummaryMarkdown() -> String {
        var md = "### 🎙️ Full Duplex Voice Session Diagnostics\n\n"
        md += "| Parameter | Current Value |\n"
        md += "|---|---|\n"
        md += "| Session Active | \(isSessionActive ? "🟢 Active" : "⚪️ Inactive") |\n"
        md += "| Activity State | `\(state.rawValue)` |\n"
        md += "| Current Signal Level | `\(String(format: "%.1f dB", currentDecibels))` |\n"
        md += "| Speech Threshold | `\(String(format: "%.1f dB", speechThresholdDb))` |\n"
        md += "| Barge-in Threshold | `\(String(format: "%.1f dB", bargeInSilenceThreshold))` |\n"
        md += "| Turn Silence Timeout | `\(String(format: "%.1fs", silenceDurationForTurnSeconds))` |\n"
        md += "| Speaking Synthesizer | \(isSpeaking ? "🗣️ Speaking" : "Silent") |\n"

        if let lastTurn = lastCompletedTurnTranscript, !lastTurn.isEmpty {
            let safeTranscript = lastTurn.replacingOccurrences(of: "|", with: "\\|")
            md += "| Last Completed Turn | \(safeTranscript) |\n"
        }
        return md
    }

}