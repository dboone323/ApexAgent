import Foundation

// MARK: - Deterministic Agent Precedence Resolver
//
// Resolves the effective execution context according to the strict priority chain:
// 1. Explicit BotProfile Overrides (per-bot instructions, memory, model, and allowed tools)
// 2. Specialized Archetype Overrides (developer, executor, controller, etc. from AgentRegistry)
// 3. Global System / Orchestrator Defaults

struct ResolvedAgentContext: Sendable, Equatable {
    let name: String
    let effectiveInstructions: String
    let effectiveProvider: ModelProvider?
    let effectiveOllamaModel: String?
    let effectiveAllowedTools: [String]
    let source: ContextSource

    enum ContextSource: String, Sendable, Equatable {
        case botProfileOverride
        case archetype
        case globalDefault
    }

    init(
        name: String,
        effectiveInstructions: String,
        effectiveProvider: ModelProvider?,
        effectiveOllamaModel: String? = nil,
        effectiveAllowedTools: [String] = [],
        source: ContextSource
    ) {
        self.name = name
        self.effectiveInstructions = effectiveInstructions
        self.effectiveProvider = effectiveProvider
        self.effectiveOllamaModel = effectiveOllamaModel
        self.effectiveAllowedTools = effectiveAllowedTools
        self.source = source
    }
}

struct AgentPrecedenceResolver: Sendable {
    /// Resolves agent execution parameters deterministically based on input specifications.
    static func resolve(
        bot: BotProfile? = nil,
        archetypeName: String? = nil,
        globalInstructions: String = "",
        globalProvider: ModelProvider = ModelRegistry.activeProvider(),
        globalAllowedTools: [String] = []
    ) -> ResolvedAgentContext {
        // 1. Explicit BotProfile Overrides
        if let bot = bot {
            let tools = !bot.allowedToolNames.isEmpty ? bot.allowedToolNames : globalAllowedTools
            var instructions = bot.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMemory = bot.memory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedMemory.isEmpty {
                if instructions.isEmpty {
                    instructions = "Working Preferences:\n\(trimmedMemory)"
                } else {
                    instructions += "\n\nWorking Preferences:\n\(trimmedMemory)"
                }
            }

            return ResolvedAgentContext(
                name: bot.name,
                effectiveInstructions: instructions.isEmpty ? globalInstructions : instructions,
                effectiveProvider: bot.modelProvider ?? globalProvider,
                effectiveOllamaModel: bot.ollamaModelOverride,
                effectiveAllowedTools: tools,
                source: .botProfileOverride
            )
        }

        // 2. Specialized Archetype Overrides
        if let archName = archetypeName, let archetype = AgentRegistry.shared.resolve(name: archName) {
            let provider: ModelProvider
            if let prefStr = archetype.modelPreference, let pref = AgentModelPreference(rawValue: prefStr) {
                provider = pref.toModelProvider
            } else {
                provider = globalProvider
            }

            let tools = !archetype.allowedTools.isEmpty ? archetype.allowedTools : globalAllowedTools
            return ResolvedAgentContext(
                name: archetype.name,
                effectiveInstructions: archetype.systemPrompt.isEmpty ? globalInstructions : archetype.systemPrompt,
                effectiveProvider: provider,
                effectiveOllamaModel: nil,
                effectiveAllowedTools: tools,
                source: .archetype
            )
        }

        // 3. Global System Defaults
        return ResolvedAgentContext(
            name: "ApexAgent",
            effectiveInstructions: globalInstructions,
            effectiveProvider: globalProvider,
            effectiveOllamaModel: nil,
            effectiveAllowedTools: globalAllowedTools,
            source: .globalDefault
        )
    }
}
