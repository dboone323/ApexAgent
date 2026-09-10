import Foundation
import FoundationModels
import AppKit

// MARK: - BotMessageSender: sendMessage logic for BotSession

extension BotSession {
    /// Sends a message to this Bot, creating a LanguageModelSession if needed,
    /// running the generation, and handling tool calls.
    func sendMessage(_ text: String, attachments: [NSImage] = []) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }
        guard !isGenerating else { return }

        // Stop any active speech
        VoiceController.shared.stopSpeaking()

        isGenerating = true
        activeAssistantMessageId = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.activeAssistantMessageId = nil
                if let continuation = self.pendingAsyncContinuation {
                    let finalResponse = self.messages.last(where: { $0.role == .assistant })?.content
                    continuation.resume(returning: finalResponse)
                    self.pendingAsyncContinuation = nil
                }
            }

            // 0. Compact context if conversation history has exceeded character limits
            await self.compactContextIfNeeded()

            // 1. Create or reset the model session with this Bot's instructions
            self.resetSession()

            // 2. Add user message
            let userMsg = ChatMessage(role: .user, content: trimmedText, attachments: attachments)
            self.appendMessage(userMsg)

            // Evaluate any onMessage triggered routines
            let currentBotId = self.bot.id
            Task { @MainActor in
                await RoutineManager.shared.dispatchOnMessage(text: trimmedText, fromBotId: currentBotId)
            }

            // 3. Add placeholder assistant message
            let assistantMsg = ChatMessage(role: .assistant, content: "", isStreaming: true)
            self.appendMessage(assistantMsg)
            let assistantId = assistantMsg.id
            self.activeAssistantMessageId = assistantId

            // 4. Launch generation
            do {
                let engine = ModelRegistry.resolveEngine(
                    for: self.bot,
                    prompt: trimmedText,
                    history: self.messages,
                    instructions: self.systemInstructions,
                    session: self.session,
                    orchestrator: self.orchestrator ?? AgentOrchestrator()
                )
                try await engine.streamResponse(
                    prompt: trimmedText,
                    attachments: attachments,
                    history: self.messages,
                    instructions: self.systemInstructions,
                    toolCallingMode: self.toolCallingMode,
                    onUpdate: { [weak self] partialContent in
                        guard let self else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            var copy = self.messages
                            copy[idx].content = partialContent
                            self.messages = copy
                        }
                    }
                )
                // Streaming finished successfully — clear isStreaming on this
                // BotSession's own message copy so pollers observe completion.
                if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                    var copy = self.messages
                    copy[idx].isStreaming = false
                    self.messages = copy
                }
            } catch {
                if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                    var copy = self.messages
                    copy[idx].content = "⚠️ Error: \(error.localizedDescription)"
                    copy[idx].isStreaming = false
                    self.messages = copy
                }
            }

            self.activeAssistantMessageId = nil
            self.isGenerating = false
        }

        // Store the task so it can be cancelled
        // (In a real multi-Bot setup each BotSession would own its task;
        // for v1 we rely on the shared orchestrator's cancellation for now)
    }

    /// Creates the appropriate AgentEngine for this Bot's model preference.
    private func makeEngine() -> any AgentEngine {
        let orch = orchestrator ?? AgentOrchestrator()
        let provider = ModelRegistry.effectiveProvider(for: bot)
        switch provider {
        case .localOllama:
            return OllamaAgentEngine(orchestrator: orch, bot: bot)
        case .localMLX:
            return MLXAgentEngine(orchestrator: orch)
        case .autoPicker, .appleOnDevice, .applePCC, .fmCLI, .cloudGemini:
            return NativeAppleEngine(orchestrator: orch, customSession: session)
        }
    }
}
