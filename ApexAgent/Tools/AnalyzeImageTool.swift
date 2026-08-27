import Foundation
import FoundationModels
import AppKit
import Vision

// MARK: - Multimodal Reader Profile

struct MultimodalReaderProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
    let instructions: String
    let model: Model
    let reasoningLevel: ContextOptions.ReasoningLevel?
    let maxResponseTokens: Int?

    init(instructions: String, model: Model, reasoningLevel: ContextOptions.ReasoningLevel? = nil, maxResponseTokens: Int? = nil) {
        self.instructions = instructions
        self.model = model
        self.reasoningLevel = reasoningLevel
        self.maxResponseTokens = maxResponseTokens
    }

    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions(instructions)
        }
        .apexAuditHooks()
        .model(model)
        .toolCallingMode(.disallowed)
        .reasoningLevel(reasoningLevel)
        .maximumResponseTokens(maxResponseTokens)
    }
}

// MARK: - Analyze Image Tool

struct AnalyzeImageTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

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
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let expandedPath = NSString(string: arguments.imagePath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: File not found at path: \(expandedPath)"
            }
            
            guard let image = NSImage(contentsOfFile: expandedPath) else {
                return "ERROR: Could not load image from: \(expandedPath). Ensure it is a valid image file."
            }
            
            let orchestrator = await self.orchestrator.orchestrator
            
            let preference = await orchestrator.modelPreference
            let instructions = "You are a visual assistant. Analyze the image and answer the user's query precisely based on the image content."
            
            let session = await MainActor.run {
                let s = createVisualSession(preference: preference, instructions: instructions)
                s.prewarm()
                return s
            }
            
            guard isMultimodalAttachmentSupported() else {
                return await performOnDeviceVisionAnalysis(imagePath: expandedPath, query: arguments.query)
            }
            
            do {
                var finalContent = ""
                let stream = session.streamResponse(options: GenerationOptions()) {
                    arguments.query
                    Attachment(image)
                }
                for try await response in stream {
                    finalContent = response.content
                }
                return finalContent.isEmpty ? await performOnDeviceVisionAnalysis(imagePath: expandedPath, query: arguments.query) : finalContent
            } catch {
                return await performOnDeviceVisionAnalysis(imagePath: expandedPath, query: arguments.query)
            }
        }
    }

    private func performOnDeviceVisionAnalysis(imagePath: String, query: String) async -> String {
        let url = URL(fileURLWithPath: imagePath)
        let handler = VNImageRequestHandler(url: url, options: [:])
        
        var results: [String] = []

        // 1. Text OCR
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        
        // 2. Barcodes / QR
        let barcodeRequest = VNDetectBarcodesRequest()

        // 3. Faces
        let faceRequest = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([textRequest, barcodeRequest, faceRequest])

            if let textResults = textRequest.results, !textResults.isEmpty {
                let text = textResults.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                if !text.isEmpty {
                    results.append("📝 **Recognized Text (OCR)**:\n\(text)")
                }
            }

            if let barcodes = barcodeRequest.results, !barcodes.isEmpty {
                let codes = barcodes.compactMap { $0.payloadStringValue }
                if !codes.isEmpty {
                    results.append("📦 **Barcodes / QR Codes**: \(codes.joined(separator: ", "))")
                }
            }

            if let faces = faceRequest.results, !faces.isEmpty {
                results.append("👤 **Detected Faces**: \(faces.count) face(s) located in image")
            }

            if results.isEmpty {
                return "🖼️ Vision analysis complete: Image loaded successfully at '\(imagePath)', but no prominent text, barcodes, or faces were detected."
            }

            return "👁️ **Apple Vision Analysis** for \"\(query)\":\n\n" + results.joined(separator: "\n\n")
        } catch {
            return "❌ Vision processing failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func createVisualSession(preference: AgentModelPreference, instructions: String) -> LanguageModelSession {
        let transcript = Transcript(entries: [])
        switch preference {
        case .localSystem:
            let model = SystemLanguageModel.default
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        case .privateCloud:
            let model = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        case .cloudGemini:
            let apiKey = KeychainManager.get(key: "geminiAPIKey") ?? ""
            let model = CloudGeminiLanguageModel(apiKey: apiKey)
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        case .localOllama:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? "http://localhost:11434") ?? URL(string: "http://localhost:11434")!
            let model = LocalOllamaLanguageModel(hostURL: hostURL)
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        case .localMLX:
            let hostURL = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
            let model = LocalMLXLanguageModel(hostURL: hostURL)
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        case .hybrid:
            let model = PrivateCloudComputeLanguageModel()
            return LanguageModelSession(profile: MultimodalReaderProfile(instructions: instructions, model: model, reasoningLevel: apexConfiguredReasoningLevel(), maxResponseTokens: apexConfiguredMaxResponseTokens()), history: transcript)
        }
    }
}
