import Foundation
import FoundationModels
import Darwin

/// Checks at runtime if the on-device FoundationModels framework exports the expected symbol
/// for LanguageModelExecutorGenerationChannel.ToolCalls.Action. This prevents segmentation faults in
/// environments/OS builds where the channel routing symbols are missing or weak-linked.
public func isLanguageModelExecutorSupported() -> Bool {
    let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_$s16FoundationModels38LanguageModelExecutorGenerationChannelV9ToolCallsV0H4CallV6ActionOMa")
    return symbol != nil
}

protocol DynamicToolRouting {
    func classifyAndRouteToolCalls(
        _ detectedToolCalls: [ParsedToolCall],
        enabledToolNames: Set<String>,
        channel: LanguageModelExecutorGenerationChannel
    ) async -> (staticCalls: [ParsedToolCall], dynamicCalls: [ParsedToolCall])
    
    func executeDynamicTool(name: String, argumentsString: String) async -> String
}

extension DynamicToolRouting {
    func classifyAndRouteToolCalls(
        _ detectedToolCalls: [ParsedToolCall],
        enabledToolNames: Set<String>,
        channel: LanguageModelExecutorGenerationChannel
    ) async -> (staticCalls: [ParsedToolCall], dynamicCalls: [ParsedToolCall]) {
        var dynamicToolCalls: [ParsedToolCall] = []
        var staticToolCalls: [ParsedToolCall] = []
        
        for tc in detectedToolCalls {
            let toolName = tc.name
            let isDynamic = await MainActor.run {
                return DynamicToolbox.shared.dynamicTools[toolName] != nil
            }
            if isDynamic && !enabledToolNames.contains(tc.name) {
                dynamicToolCalls.append(tc)
            } else {
                staticToolCalls.append(tc)
            }
        }
        
        if !staticToolCalls.isEmpty {
            guard isLanguageModelExecutorSupported() else {
                return (staticCalls: staticToolCalls, dynamicCalls: dynamicToolCalls)
            }
            for tc in staticToolCalls {
                let toolCallAction = LanguageModelExecutorGenerationChannel.ToolCalls.ToolCall.Action.appendArguments(tc.argumentsString, tokenCount: 0)
                let action = LanguageModelExecutorGenerationChannel.ToolCalls.Action.toolCall(id: tc.id, name: tc.name, action: toolCallAction)
                let event = LanguageModelExecutorGenerationChannel.ToolCalls.toolCalls(action: action)
                await channel.send(event)
            }
        }
        
        return (staticCalls: staticToolCalls, dynamicCalls: dynamicToolCalls)
    }
    
    func executeDynamicTool(name: String, argumentsString: String) async -> String {
        do {
            return try await DynamicToolbox.shared.executeTool(name: name, jsonArguments: argumentsString)
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }
}
