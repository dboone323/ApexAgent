import Foundation
import FoundationModels
import Vision
import AppKit

// MARK: - Detect Image Text Tool

struct DetectImageTextTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "detect_image_text"
    let description = "Performs fast, fully on-device optical character recognition (OCR) using macOS Vision APIs to extract all text from an image file."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Path to the image file to perform OCR on.")
        var imagePath: String
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let expandedPath = NSString(string: arguments.imagePath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                return "ERROR: File not found at path: \(expandedPath)"
            }
            
            let url = URL(fileURLWithPath: expandedPath)
            let requestHandler = VNImageRequestHandler(url: url, options: [:])
            
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            
            do {
                try requestHandler.perform([request])
                guard let observations = request.results else {
                    return "No text detected in the image."
                }
                
                let detectedText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                
                if detectedText.isEmpty {
                    return "No text was detected in the image."
                }
                
                return """
                ✅ Extracted \(detectedText.count) text segments:
                
                \(detectedText.joined(separator: "\n"))
                """
            } catch {
                return "ERROR: OCR text detection failed: \(error.localizedDescription)"
            }
        }
    }
}
