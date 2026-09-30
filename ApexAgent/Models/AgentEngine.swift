import Foundation
import AppKit
import FoundationModels
import Darwin
import os
import OSLog

// MARK: - Agent Engine Protocol

@MainActor
protocol AgentEngine {
    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws
}

// MARK: - Native Apple Engine (macOS 27 native models)

@MainActor
struct NativeAppleEngine: AgentEngine {
    let orchestrator: AgentOrchestrator
    var customSession: LanguageModelSession?

    func streamResponse(
        prompt: String,
        attachments: [NSImage],
        history: [ChatMessage],
        instructions: String,
        toolCallingMode: AgentToolCallingMode,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        // NativeAppleEngine uses customSession (from BotSession) if provided, otherwise orchestrator's session
        guard let session = customSession ?? orchestrator.session else {
            throw NSError(domain: "NativeAppleEngine", code: -1, userInfo: [NSLocalizedDescriptionKey: "LanguageModelSession is not initialized."])
        }

        let lowerPrompt = prompt.lowercased()
        let explicitlyNoTools = lowerPrompt.contains("without tools")
            || lowerPrompt.contains("without running tools")
            || lowerPrompt.contains("without using tools")
            || lowerPrompt.contains("no tools")
            || lowerPrompt.contains("don't use tools")
            || lowerPrompt.contains("do not use tools")
            || lowerPrompt.contains("without running any tools")
            || (attachments.isEmpty && AgentOrchestrator.isConversationalGreetingOrSmallTalk(prompt))

        var options = GenerationOptions()
        let effectiveMode: AgentToolCallingMode = explicitlyNoTools ? .disabled : toolCallingMode
        options.toolCallingMode = switch effectiveMode {
        case .auto: .allowed
        case .required: .required
        case .disabled: .disallowed
        }

        // Extract semantic RAG context (the portion appended to orchestrator.agentInstructions)
        let semanticContext = instructions.replacingOccurrences(of: orchestrator.agentInstructions, with: "")
        let promptWithContext = prompt + semanticContext
        let explicitToolDirective: String
        if lowerPrompt.contains("convene_meeting") {
            explicitToolDirective = "The user explicitly requested convene_meeting. Invoke convene_meeting now, preserve the requested topic and participant list exactly, and execute the concrete discussion. Do not substitute a bot-status or readiness report.\n\n"
        } else if lowerPrompt.contains("delegate_task") {
            explicitToolDirective = "The user explicitly requested delegate_task. Invoke delegate_task now with the concrete task from the user. Do not replace the task with an operational-status or readiness report.\n\n"
        } else {
            explicitToolDirective = ""
        }

        if let directMeetingArguments = directConveneMeetingArguments(from: prompt) {
            let result = try await orchestrator.toolDispatchEngine.executeToolByName(
                name: "convene_meeting",
                jsonArguments: directMeetingArguments,
                allTools: orchestrator.allTools
            )
            onUpdate(result)
            if customSession == nil, let id = orchestrator.activeAssistantMessageId {
                orchestrator.updateMessage(id: id, content: result)
                orchestrator.updateMessage(id: id, isStreaming: false)
            }
            return
        }

        if !attachments.isEmpty {
            guard isMultimodalAttachmentSupported() else {
                onUpdate("Error: On-device multimodal vision is not supported on this macOS build.")
                return
            }
            let genID = AgentSignpost.begin("NativeGenerate", detail: "multimodal")
            defer { AgentSignpost.end("NativeGenerate", genID) }
            let poiID = OSSignpostID(log: agentPointsOfInterestLog)
            os_signpost(.begin, log: agentPointsOfInterestLog, name: "Generate", signpostID: poiID)
            defer { os_signpost(.end, log: agentPointsOfInterestLog, name: "Generate", signpostID: poiID) }
            // On macOS 27 beta 4, multimodal streaming can also hang, so use
            // respond(to:) directly and surface any output before falling back.
            do {
                let attachmentNotes = if attachments.isEmpty {
                    ""
                } else {
                    "\n" + attachments.map { _ in "[image attachment]" }.joined(separator: "\n")
                }
                let multimodalPrompt = Prompt("\(promptWithContext)\(attachmentNotes)")
                let response = try await session.respond(to: multimodalPrompt, options: options)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    onUpdate(text)
                    if customSession == nil, let id = orchestrator.activeAssistantMessageId {
                        orchestrator.updateMessage(id: id, content: text)
                        orchestrator.updateMessage(id: id, isStreaming: false)
                    }
                    AgentSignpost.event("NativeGenerate.Complete", detail: "multimodal (respond-direct)")
                    return
                }
            } catch {
                Logger.provider.error("Native multimodal respond(to:) failed: \(error.localizedDescription, privacy: .public)")
            }
            onUpdate("⚠️ The on-device model returned no output for this image. Switch Model Provider to “Local Ollama” or “Cloud Gemini” to continue.")
        } else {
            // On macOS 27 beta 4, `streamResponse` hangs forever without ever
            // yielding or returning, so use `respond(to:)` directly, which DOES
            // yield a result on this beta. The app actually replies instead of
            // hanging on "thinking" or crashing on a nonexistent streaming API.
            //
            // Each turn is wrapped in a withThrowingTaskGroup timeout (90 s) so
            // that a hung model — AFM asset still downloading, beta instability,
            // or a CI environment where the model isn't installed — surfaces the
            // fallback onUpdate message instead of leaving the UI bubble empty
            // indefinitely. 90 s is well under the UI tests' 180 s total wait
            // and is also a production-quality safeguard.
            do {
                var fullText = ""
                var currentPrompt = explicitToolDirective + promptWithContext
                let maxTurns = 5

                for turn in 0..<maxTurns {
                    let turnPrompt = currentPrompt
                    let responseTask = Task { @MainActor in
                        try await session.respond(to: turnPrompt, options: options)
                    }
                    let response = try await withThrowingTaskGroup(of: LanguageModelSession.Response.self) { group in
                        group.addTask {
                            try await responseTask.value
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(90))
                            throw NSError(
                                domain: "NativeAppleEngine",
                                code: 90,
                                userInfo: [NSLocalizedDescriptionKey: "On-device model response timed out after 90 seconds."]
                            )
                        }

                        guard let response = try await group.next() else {
                            throw CancellationError()
                        }
                        group.cancelAll()
                        return response
                    }
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { break }

                    if fullText.isEmpty {
                        fullText = text
                    } else {
                        fullText += "\n\n" + text
                    }

                    onUpdate(fullText)
                    if customSession == nil, let id = orchestrator.activeAssistantMessageId {
                        orchestrator.updateMessage(id: id, content: fullText)
                    }

                    // Check if model emitted text announcing future delegation or pseudo-status without having executed it
                    let lower = text.lowercased()
                    let announcesFutureDelegation = lower.contains("will now delegate")
                        || lower.contains("delegate these tasks")
                        || lower.contains("i will delegate")
                        || lower.contains("proceed to delegate")
                        || lower.contains("delegating these tasks")
                        || (lower.contains("delegate") && lower.contains("now"))
                        || (lower.contains("delegat") && lower.contains("action"))
                        || lower.contains("performing a deep-dive")
                        || lower.contains("standing by")
                        || lower.contains("currently mapping")
                        || lower.contains("mapping & analysis phase")
                        || lower.contains("has initiated a multi-dimensional audit")
                        || lower.contains("active audit progress")
                        || lower.contains("i am monitoring their progress")
                        || lower.contains("once they have completed their respective segments")
                        || lower.contains("auditing the \"trust boundaries\"")
                        || lower.contains("auditing the trust boundaries")
                        || lower.contains("running a series of \"execution paths\"")
                        || lower.contains("running a series of execution paths")
                        || lower.contains("dispatching the following specific tasks")
                        || lower.contains("awaiting the first wave of granular results")
                        || lower.contains("observing the concurrent output")
                        || lower.contains("i am now performing a direct")
                        || lower.contains("monitoring status")
                        || lower.contains("i am currently awaiting")

                    if announcesFutureDelegation && turn < maxTurns - 1 {
                        currentPrompt = "Proceed to execute the delegation immediately using `dispatch_swarm`, `delegate_task`, or `convene_meeting`. Do not merely state what you will do or narrate in-progress status in text; invoke the tool call now to perform the actions."
                        continue
                    } else {
                        break
                    }
                }

                if !fullText.isEmpty {
                    if customSession == nil, let id = orchestrator.activeAssistantMessageId {
                        orchestrator.updateMessage(id: id, content: fullText)
                        orchestrator.updateMessage(id: id, isStreaming: false)
                    }
                    AgentSignpost.event("NativeGenerate.Complete", detail: "chars=\(fullText.count) (respond-direct)")
                    return
                }
            } catch is CancellationError {
                Logger.provider.info("Native respond(to:) was cancelled.")
                return
            } catch {
                if Task.isCancelled {
                    Logger.provider.info("Native respond(to:) was cancelled during execution.")
                    return
                }
                Logger.provider.error("Native respond(to:) failed: \(error.localizedDescription, privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            onUpdate("⚠️ The on-device model returned no output. This usually means its model asset is still downloading (enable Apple Intelligence in Settings → Siri and wait), or isn't available on this macOS build. Switch Model Provider to “Local Ollama” (if Ollama is running) or “Cloud Gemini” to continue.")
        }
    }
}

@MainActor
private func directConveneMeetingArguments(from prompt: String) -> String? {
    let lowerPrompt = prompt.lowercased()
    guard lowerPrompt.contains("convene_meeting") else { return nil }

    let participantPattern = #"participants\s*[:=]?\s*\[([^\]]+)\]"#
    guard let participantRegex = try? NSRegularExpression(pattern: participantPattern, options: [.caseInsensitive]),
          let participantMatch = participantRegex.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)),
          let participantRange = Range(participantMatch.range(at: 1), in: prompt) else {
        return nil
    }

    let participantText = String(prompt[participantRange])
    let participants = participantText
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\\\"'"))) }
        .filter { !$0.isEmpty }
    guard !participants.isEmpty else { return nil }

    let topic: String
    if let topicRange = prompt.range(of: "to discuss", options: [.caseInsensitive]) {
        topic = String(prompt[topicRange.upperBound...])
            .components(separatedBy: ". Actually").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? prompt
    } else {
        topic = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    guard let data = try? JSONSerialization.data(withJSONObject: [
        "topic": topic,
        "participants": participants
    ]) else { return nil }
    return String(data: data, encoding: .utf8)
}


// MARK: - Helper Utilities & JSON Schemas

func base64String(from image: NSImage) -> String? {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    return pngData.base64EncodedString()
}

@MainActor
func getParsedSchemas() -> [[String: Any]] {
    var array: [[String: Any]] = []

    // Extract dynamic schemas from all active tools
    let orchestrator = MCPManager.shared.orchestrator
    for tool in orchestrator.allTools {
        if let jsonStr = tool.schemaJSON,
           let data = jsonStr.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            array.append(dict)
        }
    }

    // Fall back to the bundled static schemas if dynamic extraction is empty
    if array.isEmpty {
        if let url = Bundle.main.url(forResource: "ToolSchemas", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let staticList = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            array = staticList
        }
    }

    // Inject dynamic tools from toolbox
    let dynamicSchemas = DynamicToolbox.shared.dynamicTools.values.map { $0.schema }
    array.append(contentsOf: dynamicSchemas)
    return array
}

@MainActor
func getParsedGeminiFunctionDeclarations() -> [[String: Any]] {
    let schemas = getParsedSchemas()

    // Gemini wants uppercase types for properties, e.g. "STRING", "INTEGER", "BOOLEAN", "OBJECT"
    func convertTypesUppercase(_ dict: [String: Any]) -> [String: Any] {
        var copy = dict
        if let type = copy["type"] as? String {
            copy["type"] = type.uppercased()
        }
        if let properties = copy["properties"] as? [String: Any] {
            var newProps: [String: Any] = [:]
            for (k, v) in properties {
                if let vDict = v as? [String: Any] {
                    newProps[k] = convertTypesUppercase(vDict)
                } else {
                    newProps[k] = v
                }
            }
            copy["properties"] = newProps
        }
        return copy
    }

    return schemas.map { schema in
        var decl = schema
        if let params = decl["parameters"] as? [String: Any] {
            decl["parameters"] = convertTypesUppercase(params)
        }
        return decl
    }
}

@MainActor
func getParsedSchemasJSONData() -> Data {
    let schemas = getParsedSchemas()
    return (try? JSONSerialization.data(withJSONObject: schemas)) ?? Data()
}

@MainActor
func getParsedGeminiFunctionDeclarationsJSONData() -> Data {
    let decls = getParsedGeminiFunctionDeclarations()
    return (try? JSONSerialization.data(withJSONObject: decls)) ?? Data()
}

/// Checks at runtime if the on-device FoundationModels framework exports the expected symbol
/// for constructing an image Attachment. This prevents segmentation faults in environments/OS builds
/// where the multimodal symbols are missing or weak-linked.
public func isMultimodalAttachmentSupported() -> Bool {
    let symbol1 = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_$s16FoundationModels10AttachmentV01_aB7_AppKitAA05ImageC7ContentVRszrlE_11orientationACyAFGSo7NSImageC_So26CGImagePropertyOrientationVSgtcfC")
    let symbol2 = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_$s16FoundationModels10AttachmentVA2A05ImageC7ContentVRszrlE_11orientationACyAEGSo10CGImageRefa_So0G19PropertyOrientationVSgtcfC")
    return symbol1 != nil || symbol2 != nil
}
