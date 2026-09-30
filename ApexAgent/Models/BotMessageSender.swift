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

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.activeAssistantMessageId = nil
                self.generationTask = nil
                SessionLifecycleManager.shared.unregister(sessionId: self.id)
                if let continuation = self.pendingAsyncContinuation {
                    let finalResponse = self.messages.last(where: { $0.role == .assistant })?.content
                    continuation.resume(returning: finalResponse)
                    self.pendingAsyncContinuation = nil
                }
            }

            // 0. Compact context if conversation history has exceeded character limits
            if Task.isCancelled { return }
            await self.compactContextIfNeeded()
            if Task.isCancelled { return }

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

            // 4. Launch generation via canonical AgentRequestRouter
            let request = AgentRequest(
                conversationId: self.id,
                senderIdentity: .bot(id: self.bot.id, name: self.bot.name),
                prompt: trimmedText,
                attachments: attachments,
                toolCallingMode: self.toolCallingMode
            )
            let orch = self.orchestrator ?? AgentOrchestrator()

            let terminalState = await AgentRequestRouter.shared.route(
                request,
                bot: self.bot,
                session: self.session,
                history: self.messages,
                instructions: self.systemInstructions,
                orchestrator: orch,
                onUpdate: { [weak self] partialContent in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let idx = self.messages.firstIndex(where: { $0.id == assistantId }) {
                            var copy = self.messages
                            copy[idx].content = partialContent
                            self.messages = copy
                        }
                    }
                }
            )

            if let currentMessage = self.messages.first(where: { $0.id == assistantId }) {
                let finalContent = (!terminalState.isSuccess || currentMessage.content.isEmpty)
                    ? terminalState.userFacingMessage
                    : currentMessage.content
                self.updateMessage(id: assistantId, content: finalContent)
                self.updateMessage(id: assistantId, isStreaming: false)
            }

            self.activeAssistantMessageId = nil
            self.isGenerating = false
        }

        generationTask = task
        SessionLifecycleManager.shared.register(task: task, forSessionId: self.id)
    }

}
