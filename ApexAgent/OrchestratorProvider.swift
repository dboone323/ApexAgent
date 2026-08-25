import Foundation
import FoundationModels
import Observation
import SwiftData
import AppKit
import SharedKit

/// Protocol for providing access to the AgentOrchestrator instance.
/// This replaces direct access to `AgentOrchestrator.shared` static property,
/// enabling dependency injection and better testability.
@MainActor
protocol OrchestratorProvider: Sendable {
    var orchestrator: AgentOrchestrator { get }
    var dataBus: AppGroupDataBus { get }
    func sessionForAgent(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        allowedTools: [String],
        toolCallingMode: GenerationOptions.ToolCallingMode,
        reasoningLevel: ContextOptions.ReasoningLevel?,
        maxResponseTokens: Int?,
        history: Transcript?
    ) -> LanguageModelSession
}
