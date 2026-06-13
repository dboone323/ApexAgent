import Foundation
import FoundationModels
import AppKit

// MARK: - Multimodal Reader Profile

struct MultimodalReaderProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    
    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
        }
        .model(model)
        .toolCallingMode(.disallowed)
    }
}

// MARK: - Analyze Image Tool

struct AnalyzeImageTool: Tool {
    let name = "analyze_image"
    let description = "Analyzes an image file locally using on-device vision/multimodal capabilities to answer questions about its content."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path to the image file to analyze.")
        var imagePath: String
        
        @Guide(description: "What to look for or analyze in the image (e.g., 'describe this image', 'read the error message').")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments) {
            let expandedPath = NSString(string: arguments.imagePath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: File not found at path: \(expandedPath)"
            }
            
            guard let image = NSImage(contentsOfFile: expandedPath) else {
                return "ERROR: Could not load image from: \(expandedPath). Ensure it is a valid image file."
            }
            
            guard let orchestrator = await AgentOrchestrator.shared else {
                return "ERROR: AgentOrchestrator is not available"
            }
            
            let preference = await orchestrator.modelPreference
            let instructions = "You are a visual assistant. Analyze the image and answer the user's query precisely based on the image content."
            
            let session = await MainActor.run {
                let s = createVisualSession(preference: preference, instructions: instructions)
                s.prewarm()
                return s
            }
            
            var finalContent = ""
            let stream = session.streamResponse(options: GenerationOptions()) {
                arguments.query
                Attachment(image)
            }
            for try await response in stream {
                finalContent = response.content
            }
            return finalContent
        }
    }

    @MainActor
    private func createVisualSession(preference: AgentModelPreference, instructions: String) -> LanguageModelSession {
        let transcript = Transcript(entries: [])
        switch preference {
        case .localSystem:
            let model = SystemLanguageModel.default
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model), history: transcript)
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model), history: transcript)
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model), history: transcript)
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model), history: transcript)
        case .hybrid:
            let model = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model), history: transcript)
        }
    }
}
