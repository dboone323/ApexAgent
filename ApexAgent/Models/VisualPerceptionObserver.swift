import Foundation
import Vision
import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - Visual Perception Structures

public struct VisualBoundingBox: Sendable, Codable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let label: String
    public let confidence: Double

    public init(x: Double, y: Double, width: Double, height: Double, label: String, confidence: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.label = label
        self.confidence = confidence
    }

    /// Converts normalized Vision coordinates (origin bottom-left, [0..1])
    /// to AppKit display coordinates (origin top-left of the target display rect).
    public func toDisplayRect(displayBounds: CGRect) -> CGRect {
        let pixelX = displayBounds.origin.x + (x * displayBounds.width)
        let pixelY = displayBounds.origin.y + ((1.0 - y - height) * displayBounds.height)
        let pixelW = width * displayBounds.width
        let pixelH = height * displayBounds.height
        return CGRect(x: pixelX, y: pixelY, width: pixelW, height: pixelH)
    }
}

public struct VisualPerceptionFinding: Sendable, Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let detectedText: String
    public let category: Category
    public let boundingBoxes: [VisualBoundingBox]
    public let suggestion: String?

    public enum Category: String, Sendable, Codable {
        case errorDialog = "error_dialog"
        case buildFailure = "build_failure"
        case terminalPanic = "terminal_panic"
        case promptNotification = "prompt_notification"
        case generalInfo = "general_info"
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        detectedText: String,
        category: Category,
        boundingBoxes: [VisualBoundingBox],
        suggestion: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.detectedText = detectedText
        self.category = category
        self.boundingBoxes = boundingBoxes
        self.suggestion = suggestion
    }
}

// MARK: - VisualPerceptionObserver

@MainActor
public final class VisualPerceptionObserver: ObservableObject {
    public static let shared = VisualPerceptionObserver()

    @Published public private(set) var isObserving: Bool = false
    @Published public private(set) var latestFindings: [VisualPerceptionFinding] = []
    @Published public private(set) var lastProcessedTime: Date?

    private var observationTask: Task<Void, Never>?

    public init() {}

    /// Start autonomous observation with a specified interval (default 3 seconds).
    public func startObserving(intervalSeconds: Double = 3.0, orchestrator: AgentOrchestrator? = nil) {
        guard !isObserving else { return }
        isObserving = true

        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self, self.isObserving else { break }
                await self.performObservationPass(orchestrator: orchestrator)
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    public func stopObserving() {
        isObserving = false
        observationTask?.cancel()
        observationTask = nil
    }

    /// Performs a single visual analysis pass across available screen buffer frames or screenshot.
    public func performObservationPass(orchestrator: AgentOrchestrator? = nil) async {
        let streamer = ScreenStreamer.shared
        guard let latestImage = streamer.circularBuffer.last else {
            return
        }

        guard let cgImage = latestImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        let findings = await Self.analyzeCGImage(cgImage)
        self.latestFindings = findings
        self.lastProcessedTime = Date()

        // Proactively notify orchestrator if high-severity findings (errors, panics) are identified
        if let firstError = findings.first(where: { $0.category == .errorDialog || $0.category == .buildFailure || $0.category == .terminalPanic }) {
            if let orch = orchestrator, let suggestion = firstError.suggestion {
                orch.proactiveAuditResult = "[Visual Observer] \(firstError.category.rawValue): \(suggestion)"
            }
        }
    }

    /// Analyzes a CGImage using real Vision text recognition and classification.
    public static func analyzeCGImage(_ cgImage: CGImage) async -> [VisualPerceptionFinding] {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil, let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                var fullText = ""
                var boxes: [VisualBoundingBox] = []

                for obs in observations {
                    guard let topCandidate = obs.topCandidates(1).first else { continue }
                    let text = topCandidate.string
                    fullText += text + "\n"

                    let box = VisualBoundingBox(
                        x: obs.boundingBox.origin.x,
                        y: obs.boundingBox.origin.y,
                        width: obs.boundingBox.width,
                        height: obs.boundingBox.height,
                        label: text,
                        confidence: Double(topCandidate.confidence)
                    )
                    boxes.append(box)
                }

                let category = Self.classifyTextContent(fullText)
                let suggestion = Self.generateSuggestion(category: category, text: fullText)

                if boxes.isEmpty {
                    continuation.resume(returning: [])
                } else {
                    let finding = VisualPerceptionFinding(
                        detectedText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category,
                        boundingBoxes: boxes,
                        suggestion: suggestion
                    )
                    continuation.resume(returning: [finding])
                }
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// Categorizes visual screen content based on observed text cues.
    public static func classifyTextContent(_ text: String) -> VisualPerceptionFinding.Category {
        let lower = text.lowercased()
        if lower.contains("fatal error") || lower.contains("panic:") || lower.contains("segmentation fault") || lower.contains("traceback (most recent call last)") {
            return .terminalPanic
        } else if lower.contains("build failed") || lower.contains("compilation error") || (lower.contains("error: ") && lower.contains(".swift:")) {
            return .buildFailure
        } else if lower.contains("an error occurred") || lower.contains("unexpected error") || lower.contains("permission denied") {
            return .errorDialog
        } else if lower.contains("notification") || lower.contains("alert") || lower.contains("would you like to") {
            return .promptNotification
        } else {
            return .generalInfo
        }
    }

    /// Formulates proactive suggestions based on the category of finding.
    public static func generateSuggestion(category: VisualPerceptionFinding.Category, text: String) -> String? {
        switch category {
        case .terminalPanic:
            return "Terminal crash detected on screen. Recommend inspecting stack trace and running dynamic diagnostic tools."
        case .buildFailure:
            return "Compiler error detected on screen. Recommend reviewing recent source modifications and rebuilding."
        case .errorDialog:
            return "System or application error dialog detected. Recommend verifying permissions or inspecting OSLog."
        case .promptNotification:
            return "User prompt or confirmation modal visible on screen."
        case .generalInfo:
            return nil
        }
    }
}
