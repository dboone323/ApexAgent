import Foundation
import Observation
import Speech
import AVFoundation

public enum TTSProvider: String, CaseIterable, Sendable {
    case system = "System (macOS)"
    case elevenLabs = "ElevenLabs"
}

@Observable
@MainActor
final class VoiceController: NSObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = VoiceController()
    
    @ObservationIgnored private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var recognitionTask: SFSpeechRecognitionTask?
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    
    @ObservationIgnored private var _speechSynthesizer: AVSpeechSynthesizer?
    private var speechSynthesizer: AVSpeechSynthesizer {
        if let synth = _speechSynthesizer {
            return synth
        }
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        _speechSynthesizer = synth
        return synth
    }
    
    private(set) var isRecording = false
    private(set) var isSpeaking = false
    
    var selectedProvider: TTSProvider = .system
    @ObservationIgnored private var audioPlayer: AVAudioPlayer?
    
    override init() {
        super.init()
    }
    
    private(set) var permissionGranted: Bool = false

    func requestPermissions() async -> Bool {
        let result = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    DispatchQueue.main.async {
                        let granted = authStatus == .authorized && audioGranted
                        if !granted {
                            print("[VoiceController] Permission denied — speech= \(authStatus), audio= \(audioGranted)")
                        }
                        if self.permissionGranted != granted {
                            self.permissionGranted = granted
                        }
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
        if self.permissionGranted != result {
            self.permissionGranted = result
        }
        return result
    }
    
    func startRecording(onTranscription: @escaping (String) -> Void) throws {
        guard !audioEngine.isRunning else { return }
        
        // Cancel any active speech or recognition
        stopSpeaking()
        if recognitionTask != nil {
            recognitionTask?.cancel()
            recognitionTask = nil
        }
        
        let localeId = UserDefaults.standard.string(forKey: "apex.voiceLocale") ?? "en-US"
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "VoiceController", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognition is not available on this system. Check System Settings ➔ Privacy & Security ➔ Speech Recognition."])
        }

        recognizer.delegate = self

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        let request = recognitionRequest
        // macOS 27 deprecates installTap(onBus:bufferSize:format:block:); the
        // replacement is __installTapOnBus(_:bufferSize:format:error:block:)
        // (its `error:` is a Swift-overlay placeholder of type () on this SDK,
        // so it cannot surface an NSError here).
        try inputNode.__installTap(onBus: 0, bufferSize: 1024, format: recordingFormat, error: ()) { buffer, _ in
            request.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { result, error in
            Task { @MainActor in
                var isFinal = false
                if let result = result {
                    onTranscription(result.bestTranscription.formattedString)
                    isFinal = result.isFinal
                }
                
                if error != nil || isFinal {
                    self.audioEngine.stop()
                    inputNode.removeTap(onBus: 0)
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    if self.isRecording {
                        self.isRecording = false
                    }
                }
            }
        }
        
        if !isRecording {
            isRecording = true
        }
        print("Speech recognition started.")
    }
    
    func stopRecording() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        if isRecording {
            isRecording = false
        }
        print("Speech recognition stopped.")
    }
    
    func speak(_ text: String) {
        stopSpeaking()
        
        // Clean speech text (strip markdown format)
        let cleanText = stripMarkdown(text)
        
        if selectedProvider == .elevenLabs, let key = UserDefaults.standard.string(forKey: "apex.elevenLabsKey"), !key.isEmpty {
            speakWithElevenLabs(text: cleanText, key: key)
        } else {
            speakWithSystem(text: cleanText)
        }
    }
    
    private func speakWithSystem(text: String) {
        let utterance = AVSpeechUtterance(string: text)
        let localeId = UserDefaults.standard.string(forKey: "apex.voiceLocale") ?? "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: localeId) ?? AVSpeechSynthesisVoice(language: "en-US")
        
        let configuredRate = UserDefaults.standard.float(forKey: "apex.voiceSpeechRate")
        utterance.rate = configuredRate > 0 ? configuredRate : 0.52 // Natural speaking rate
        
        speechSynthesizer.speak(utterance)
        if !isSpeaking {
            isSpeaking = true
        }
    }
    
    private func speakWithElevenLabs(text: String, key: String) {
        let voiceId = UserDefaults.standard.string(forKey: "apex.elevenLabsVoiceId") ?? "21m00Tcm4TlvDq8ikWAM" // Default voice
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)") else {
            speakWithSystem(text: text)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": text, "model_id": "eleven_turbo_v2_5"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        if !isSpeaking {
            isSpeaking = true
        }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 {
                    self.audioPlayer = try AVAudioPlayer(data: data)
                    self.audioPlayer?.delegate = self
                    self.audioPlayer?.play()
                } else {
                    print("[VoiceController] ElevenLabs HTTP Error. Falling back to system TTS.")
                    self.speakWithSystem(text: text)
                }
            } catch {
                print("[VoiceController] ElevenLabs Network Error: \(error). Falling back to system TTS.")
                self.speakWithSystem(text: text)
            }
        }
    }
    
    func stripMarkdown(_ text: String) -> String {
        var clean = text
        
        // 1. Strip code blocks completely (e.g. ```swift ... ```)
        if let regex = try? NSRegularExpression(pattern: "```[\\s\\S]*?```", options: []) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        // 2. Strip images and link destinations, keeping only link text: e.g. [Link Text](http://example.com) -> Link Text
        // First images: ![alt](url) -> ""
        if let regex = try? NSRegularExpression(pattern: "!\\[.*?\\]\\(.*?\\)", options: []) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        // Then links: [text](url) -> text
        if let regex = try? NSRegularExpression(pattern: "\\[(.*?)\\]\\(.*?\\)", options: []) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "$1")
        }
        
        // 3. Strip blockquote indicators: e.g. > text -> text
        if let regex = try? NSRegularExpression(pattern: "^\\s*>\\s*", options: [.anchorsMatchLines]) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        // 4. Strip headers: e.g. ### Header -> Header
        if let regex = try? NSRegularExpression(pattern: "^\\s*#+\\s*", options: [.anchorsMatchLines]) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        // 5. Strip bullet list markers: e.g. - item -> item, * item -> item
        if let regex = try? NSRegularExpression(pattern: "^\\s*[-*+]\\s+", options: [.anchorsMatchLines]) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        // 6. Strip numbered list markers: e.g. 1. item -> item
        if let regex = try? NSRegularExpression(pattern: "^\\s*\\d+\\.\\s+", options: [.anchorsMatchLines]) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        // 7. Strip inline styles: *bold*, `code`, _italic_, ~strike~
        clean = clean
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "⚠️", with: "")
            
        // 8. Strip horizontal dividers: ---
        if let regex = try? NSRegularExpression(pattern: "^\\s*-{3,}\\s*$", options: [.anchorsMatchLines]) {
            let range = NSRange(clean.startIndex..., in: clean)
            clean = regex.stringByReplacingMatches(in: clean, options: [], range: range, withTemplate: "")
        }
        
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    func stopSpeaking() {
        if let synth = _speechSynthesizer, synth.isSpeaking {
            synth.stopSpeaking(at: .word)
        }
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        if isSpeaking {
            isSpeaking = false
        }
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if VoiceController.shared.isSpeaking {
                VoiceController.shared.isSpeaking = false
            }
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if VoiceController.shared.isSpeaking {
                VoiceController.shared.isSpeaking = false
            }
        }
    }
    
    // MARK: - AVAudioPlayerDelegate
    
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if VoiceController.shared.isSpeaking {
                VoiceController.shared.isSpeaking = false
            }
        }
    }
}
