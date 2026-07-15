import Foundation
import Speech
import AVFoundation

@MainActor
class VoiceController: NSObject, ObservableObject, SFSpeechRecognizerDelegate, AVSpeechSynthesizerDelegate {
    static let shared = VoiceController()
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    
    @Published private(set) var isRecording = false
    @Published private(set) var isSpeaking = false
    
    override init() {
        super.init()
        speechSynthesizer.delegate = self
    }
    
    func requestPermissions() async -> Bool {
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authStatus in
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    DispatchQueue.main.async {
                        let granted = authStatus == .authorized && audioGranted
                        continuation.resume(returning: granted)
                    }
                }
            }
        }
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
        recognizer?.delegate = self
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "VoiceController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        
        let request = recognitionRequest
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        recognitionTask = recognizer?.recognitionTask(with: recognitionRequest) { result, error in
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
                    self.isRecording = false
                }
            }
        }
        
        isRecording = true
        print("Speech recognition started.")
    }
    
    func stopRecording() {
        guard audioEngine.isRunning else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false
        print("Speech recognition stopped.")
    }
    
    func speak(_ text: String) {
        stopSpeaking()
        
        // Clean speech text (strip markdown format)
        let cleanText = stripMarkdown(text)
        
        let utterance = AVSpeechUtterance(string: cleanText)
        let localeId = UserDefaults.standard.string(forKey: "apex.voiceLocale") ?? "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: localeId) ?? AVSpeechSynthesisVoice(language: "en-US")
        
        let configuredRate = UserDefaults.standard.float(forKey: "apex.voiceSpeechRate")
        utterance.rate = configuredRate > 0 ? configuredRate : 0.52 // Natural speaking rate
        
        speechSynthesizer.speak(utterance)
        isSpeaking = true
    }
    
    private func stripMarkdown(_ text: String) -> String {
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
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            VoiceController.shared.isSpeaking = false
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            VoiceController.shared.isSpeaking = false
        }
    }
}
