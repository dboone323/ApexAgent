import Foundation
import FoundationModels
import SharedKit

// MARK: - Agent Session Coordinator
//
// Encapsulates LanguageModelSession creation, model resolution, context compaction,
// transcript hydration, and sliding context pruning.

@MainActor
final class AgentSessionCoordinator: Sendable {
    static let shared = AgentSessionCoordinator()

    static let contextCompactionThreshold: Int = 12000
    static let contextPruningMaxChars: Int = 500
    static let rehydrationWindowSize: Int = 4
    static let defaultOllamaURLString = "http://localhost:11434"

    init() {}

    private struct CompactionProfile<Model: LanguageModel>: LanguageModelSession.DynamicProfile {
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

    func createCompactionSession(model: any LanguageModel, instructions: String) -> LanguageModelSession {
        func helper<M: LanguageModel>(_ m: M) -> LanguageModelSession {
            let profile = CompactionProfile(instructions: instructions, model: m)
            return LanguageModelSession(profile: profile, history: Transcript(entries: []))
        }
        return helper(model)
    }

    func prunedContent(_ content: String, maxChars: Int = contextPruningMaxChars) -> String {
        if content.count <= maxChars {
            return content
        }
        let keepLength = maxChars - 100
        let prefix = content.prefix(keepLength)
        return prefix + "\n\n[... content truncated to conserve context space ...]"
    }

    func buildRehydratedTranscript(messages: [ChatMessage], instructions: String) -> Transcript {
        var transcriptEntries: [Transcript.Entry] = []
        let systemInstructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: []
        )
        transcriptEntries.append(.instructions(systemInstructions))

        // Apply Sliding Rehydration Window: only rehydrate the last messages
        let rehydrationMessages = messages.suffix(Self.rehydrationWindowSize)
        for msg in rehydrationMessages {
            let truncated = prunedContent(msg.content)
            switch msg.role {
            case .user:
                let promptSegment = Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: truncated))])
                transcriptEntries.append(.prompt(promptSegment))
            case .assistant:
                let responseSegment = Transcript.Response(
                    id: UUID().uuidString,
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: truncated))]
                )
                transcriptEntries.append(.response(responseSegment))
            case .system:
                let instSegment = Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: truncated))],
                    toolDefinitions: []
                )
                transcriptEntries.append(.instructions(instSegment))
            }
        }

        return Transcript(entries: transcriptEntries)
    }

    func resolveModel(
        preference: AgentModelPreference,
        prompt: String = "",
        instructions: String = "",
        tools: [String] = [],
        multiAgentModeEnabled: Bool = false
    ) -> any LanguageModel {
        switch preference {
        case .autoPicker:
            let (resolved, _) = ModelRegistry.resolveProviderForTask(
                preferred: .autoPicker,
                prompt: prompt,
                instructions: instructions,
                tools: tools
            )
            switch resolved {
            case .cloudGemini:
                let apiKey = ModelRegistry.geminiAPIKey()
                return CloudGeminiLanguageModel(apiKey: apiKey)
            case .localOllama:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? Self.defaultOllamaURLString) ?? URL(string: Self.defaultOllamaURLString)!
                return LocalOllamaLanguageModel(hostURL: host)
            case .localMLX:
                let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
                return LocalMLXLanguageModel(hostURL: host)
            case .applePCC:
                if AgentOrchestrator.isPrivateCloudComputeAvailable() {
                    return PrivateCloudComputeLanguageModel()
                } else {
                    return SystemLanguageModel.default
                }
            default:
                return SystemLanguageModel.default
            }
        case .localSystem:
            return SystemLanguageModel.default
        case .privateCloud:
            if AgentOrchestrator.isPrivateCloudComputeAvailable() {
                return PrivateCloudComputeLanguageModel()
            } else {
                return SystemLanguageModel.default
            }
        case .cloudGemini:
            let apiKey = ModelRegistry.geminiAPIKey()
            return CloudGeminiLanguageModel(apiKey: apiKey)
        case .localOllama:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.ollamaHostURL") ?? Self.defaultOllamaURLString) ?? URL(string: Self.defaultOllamaURLString)!
            return LocalOllamaLanguageModel(hostURL: host)
        case .localMLX:
            let host = URL(string: UserDefaults.standard.string(forKey: "apex.mlxHost") ?? LocalMLXLanguageModel.defaultHostURLString) ?? URL(string: LocalMLXLanguageModel.defaultHostURLString)!
            return LocalMLXLanguageModel(hostURL: host)
        case .hybrid:
            if multiAgentModeEnabled {
                return SystemLanguageModel.default
            } else if AgentOrchestrator.isPrivateCloudComputeAvailable() {
                return PrivateCloudComputeLanguageModel()
            } else {
                return SystemLanguageModel.default
            }
        }
    }
}
