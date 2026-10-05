import Foundation
import FoundationModels
import AppKit

// MARK: - BotMessageSender: sendMessage logic for BotSession

extension BotSession {
    /// True when a raw `@handle` from a message refers to this bot, tolerating
    /// case, hyphens, underscores, and spaces ("Code Architect" / "@code-architect").
    static func handleMatches(handle: String, bot: BotProfile) -> Bool {
        let cleaned = handle.lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if cleaned == SpaceParticipant.normalizeHandle(bot.name).replacingOccurrences(of: "-", with: "") {
            return true
        }
        return cleaned == bot.name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    /// Sends a message to this Bot, creating a LanguageModelSession if needed,
    /// running the generation, and handling tool calls.
    func sendMessage(_ text: String, attachments: [NSImage] = []) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsToSend = !attachments.isEmpty ? attachments : self.pendingAttachments
        guard !trimmedText.isEmpty || !attachmentsToSend.isEmpty else { return }

        // If currently generating, queue the prompt to execute right after
        if isGenerating {
            queuedPrompts.append(QueuedPrompt(id: UUID(), text: trimmedText, attachments: attachmentsToSend))
            self.pendingAttachments = []
            return
        }

        // Drain pending attachments
        self.pendingAttachments = []

        // Stop any active speech
        VoiceController.shared.stopSpeaking()

        isGenerating = true
        activeAssistantMessageId = nil
        let taskId = UUID()

        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isGenerating = false
                self.activeAssistantMessageId = nil
                self.generationTask = nil
                SessionLifecycleManager.shared.unregister(sessionId: self.id, taskId: taskId)
                if let continuation = self.pendingAsyncContinuation {
                    let finalResponse = self.messages.last(where: { $0.role == .assistant })?.content
                    continuation.resume(returning: finalResponse)
                    self.pendingAsyncContinuation = nil
                }
                self.processNextQueuedPromptIfNeeded()
            }

            // 0. Compact context if conversation history has exceeded character limits
            if Task.isCancelled { return }
            await self.compactContextIfNeeded()
            if Task.isCancelled { return }

            // 1. Create or reset the model session with this Bot's instructions
            self.resetSession()

            // 2. Add user message
            let userMsg = ChatMessage(id: UUID(), role: .user, content: trimmedText, timestamp: Date(), attachments: attachmentsToSend)
            self.appendMessage(userMsg)

            // Evaluate any onMessage triggered routines
            let currentBotId = self.bot.id
            Task { @MainActor in
                await RoutineManager.shared.dispatchOnMessage(text: trimmedText, fromBotId: currentBotId)
            }

            // 3. Add placeholder assistant message
            let assistantMsg = ChatMessage(id: UUID(), role: .assistant, content: "", timestamp: Date(), isStreaming: true, botName: self.bot.name)
            self.appendMessage(assistantMsg)
            let assistantId = assistantMsg.id
            self.activeAssistantMessageId = assistantId

            // 4. Launch generation via canonical AgentRequestRouter
            let mentionedHandles = SpaceManager.extractMentions(from: trimmedText)
            let targetsSelf = mentionedHandles.contains { Self.handleMatches(handle: $0, bot: self.bot) }
                || mentionedHandles.contains { SpaceManager.broadcastHandles.contains($0) }

            let request = AgentRequest(
                id: UUID(),
                senderIdentity: .bot(id: self.bot.id, name: self.bot.name),
                prompt: trimmedText,
                isDirectMention: targetsSelf,
                attachments: attachmentsToSend,
                toolCallingMode: self.toolCallingMode
            )
            let orch = self.orchestrator ?? AgentOrchestrator()

            let terminalState = await AgentRequestRouter.shared.route(
                request,
                bot: self.bot,
                session: self.session,
                history: self.messages,
                instructions: AgentRequestRouter.applyingDirectAddressPolicy(
                    base: self.systemInstructions,
                    isDirectMention: targetsSelf
                ),
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

            // 5. Chained Bot @Mentions: If the bot tags another known bot in its reply, pull them in!
            if let currentMessage = self.messages.first(where: { $0.id == assistantId }),
               !currentMessage.content.isEmpty,
               !Task.isCancelled {
                let mentions = SpaceManager.extractMentions(from: currentMessage.content)
                if !mentions.isEmpty, let bm = self.botManager ?? self.orchestrator?.botManager {
                    let mentionedBots = SpaceManager.matchBots(for: mentions, in: nil, botManager: bm)
                        .filter { $0.id != self.bot.id }
                    if !mentionedBots.isEmpty {
                        await self.dispatchMentionedBotsInSession(
                            mentionedBots: Array(mentionedBots.prefix(2)),
                            triggeredBy: self.bot,
                            triggerPrompt: currentMessage.content
                        )
                    }
                }
            }

            self.isGenerating = false
        }

        generationTask = task
        SessionLifecycleManager.shared.register(task: task, forSessionId: self.id, taskId: taskId)
    }

    /// Asynchronously sends a prompt to the bot and awaits the completed response string.
    func sendMessageAsync(_ text: String, attachments: [NSImage] = []) async -> String? {
        if isGenerating {
            return nil
        }
        await send(prompt: text, attachments: attachments)
        return messages.last(where: { $0.role == .assistant })?.content
    }

    /// Dispatches chained turns for other bots that were @mentioned in a 1:1 conversation.
    func dispatchMentionedBotsInSession(
        mentionedBots: [BotProfile],
        triggeredBy: BotProfile,
        triggerPrompt: String
    ) async {
        guard !Task.isCancelled else { return }
        let orch = self.orchestrator ?? AgentOrchestrator()

        for targetBot in mentionedBots {
            guard !Task.isCancelled else { break }

            let assistantMsg = ChatMessage(
                id: UUID(),
                role: .assistant,
                content: "",
                timestamp: Date(),
                isStreaming: true,
                botName: targetBot.name
            )
            self.appendMessage(assistantMsg)
            let assistantId = assistantMsg.id
            self.activeAssistantMessageId = assistantId

            let instructions = targetBot.systemInstructions + """
            
            [COLLABORATION CONTEXT]: You are \(targetBot.name). You were explicitly mentioned via @\(SpaceParticipant.normalizeHandle(targetBot.name)) by \(triggeredBy.name) in this conversation.
            Respond directly to the task or question that was addressed to you concisely.
            """

            let request = AgentRequest(
                id: UUID(),
                senderIdentity: .bot(id: targetBot.id, name: targetBot.name),
                prompt: triggerPrompt,
                // This bot was explicitly named by another bot — it owns the
                // task and must answer it, not bounce it to a third agent.
                isDirectMention: true,
                toolCallingMode: self.toolCallingMode
            )

            let terminalState = await AgentRequestRouter.shared.route(
                request,
                bot: targetBot,
                session: self.session,
                history: self.messages,
                instructions: AgentRequestRouter.applyingDirectAddressPolicy(
                    base: instructions,
                    isDirectMention: true
                ),
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
        }
    }
}
