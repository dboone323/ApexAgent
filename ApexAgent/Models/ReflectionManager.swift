import Foundation
import FoundationModels
import SwiftData

@MainActor
final class ReflectionManager {
    static let shared = ReflectionManager()

    private init() {}

    /// Checks the session history after a successful assistant message generation.
    /// If a previous build or compilation failure was resolved by subsequent actions,
    /// triggers a background reflection Task to summarize and save it as a reusable skill.
    func reflectIfResolved(
        prompt: String,
        history: [ChatMessage],
        orchestrator: AgentOrchestrator
    ) {
        // Look for error indicators in past user or tool results, followed by successful build/test outcomes
        var hasFailure = false
        var failureDetails = ""

        for msg in history {
            let content = msg.content.lowercased()
            if content.contains("error:") ||
               content.contains("failed with exit code") ||
               content.contains("build failed") ||
               content.contains("fatal error:") ||
               content.contains("process missing required entitlement") {
                hasFailure = true
                failureDetails += msg.content + "\n"
            }
        }

        // Ensure there was a failure that got resolved in the latest assistant response
        guard hasFailure else { return }

        let latestAssistantText = history.last?.content ?? ""
        let latestAssistantLower = latestAssistantText.lowercased()

        let hasSuccess = latestAssistantLower.contains("build succeeded") ||
                         latestAssistantLower.contains("test succeeded") ||
                         latestAssistantLower.contains("completed successfully") ||
                         latestAssistantLower.contains("success:") ||
                         latestAssistantLower.contains("build complete!")

        guard hasSuccess else { return }

        // In tests, skip the detached background reflection Task: it can outlive
        // the test (embedding/SwiftData work) and keep the test helper process
        // resident. Driven by APEX_TEST_MODE=1 (set in ApexAgentTests.init()).
        let isTestMode = getenv("APEX_TEST_MODE").flatMap({ String(cString: $0) }) == "1"
        guard !isTestMode else { return }

        // Launch background reflection Task to compile the solution
        Task.detached(priority: .background) {
            await self.compileAndSaveSkill(
                prompt: prompt,
                failureDetails: failureDetails,
                resolution: latestAssistantText,
                orchestrator: orchestrator
            )
        }
    }

    private func compileAndSaveSkill(
        prompt: String,
        failureDetails: String,
        resolution: String,
        orchestrator: AgentOrchestrator
    ) async {
        print("🧠 [ReflectionManager]: Traced error resolution! Generating procedural skill...")

        let model = await MainActor.run { orchestrator.createModelInstance() }
        let systemPrompt = """
        You are the Reflection Engine of ApexAgent. Your task is to analyze a resolved build/compilation failure and compile it into a reusable "procedural skill" schema.

        Respond ONLY with a valid JSON object matching this schema:
        {
          "skillName": "lowercase_snake_case_identifier",
          "skillDescription": "Short description of the warning/error and how it is fixed.",
          "triggerPatterns": ["substring of compiler error", "key warning details"],
          "resolutionSteps": "Clear steps or commands executed to resolve this issue."
        }
        """

        // Use helper with empty transcript to create session
        let session = createSession(model: model, systemPrompt: systemPrompt, orchestrator: orchestrator)

        struct ReflectionTimeoutError: LocalizedError {
            var errorDescription: String? { "Reflection generation timed out." }
        }

        let requestText = """
        Original prompt: \(prompt)

        Compilation Failures:
        \(failureDetails.prefix(2000))

        Resolution Details:
        \(resolution.prefix(2000))
        """

        do {
            let responseText: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let response = try await session.respond(
                        to: Prompt(requestText),
                        options: GenerationOptions(toolCallingMode: .allowed)
                    )
                    return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw ReflectionTimeoutError()
                }

                guard let first = try await group.next() else {
                    group.cancelAll()
                    return ""
                }
                group.cancelAll()
                return first
            }

            // Clean markdown blocks if LLM wrapped JSON in ```json
            var cleanedJSON = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanedJSON.hasPrefix("```") {
                let lines = cleanedJSON.components(separatedBy: "\n")
                let filtered = lines.filter { !$0.hasPrefix("```") }
                cleanedJSON = filtered.joined(separator: "\n")
            }

            guard let jsonData = cleanedJSON.data(using: .utf8),
                  let skillDict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let skillName = skillDict["skillName"] as? String,
                  let skillDesc = skillDict["skillDescription"] as? String,
                  let triggerPatterns = skillDict["triggerPatterns"] as? [String],
                  let resolutionSteps = skillDict["resolutionSteps"] as? String else {
                print("🧠 [ReflectionManager]: Failed to parse reflection JSON: \(responseText)")
                return
            }

            // Save JSON to ~/.apex/skills/
            let fileManager = FileManager.default
            let skillsDir = ApexAgentStoragePaths.skills
            try? fileManager.createDirectory(at: skillsDir, withIntermediateDirectories: true)

            let sanitizedName = skillName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonPath = skillsDir.appendingPathComponent("\(sanitizedName)_procedural.json")

            let manifest: [String: Any] = [
                "name": sanitizedName,
                "description": skillDesc,
                "trigger_patterns": triggerPatterns,
                "resolution": resolutionSteps
            ]

            if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted) {
                try? manifestData.write(to: jsonPath, options: .atomic)
                print("🧠 [ReflectionManager]: Saved procedural skill to: \(jsonPath.path)")
            }

            // Save to SwiftData long-term AgentMemory so it gets hydrated into RAG
            await MainActor.run {
                guard let context = orchestrator.modelContext else { return }

                let key = "procedural_skill_\(sanitizedName)"
                let value = "Procedural Skill: \(skillDesc)\nTrigger conditions: \(triggerPatterns.joined(separator: ", "))\nSolution: \(resolutionSteps)"

                // Check if memory already exists
                let descriptor = FetchDescriptor<AgentMemory>(predicate: #Predicate { $0.key == key })
                if let existing = try? context.fetch(descriptor).first {
                    existing.val = value
                    existing.timestamp = Date()
                    // Re-calculate embedding
                    if let vector = EmbeddingHelper.getVector(for: value) {
                        existing.embeddingData = EmbeddingHelper.serialize(vector)
                    }
                } else {
                    let memory = AgentMemory(key: key, val: value)
                    context.insert(memory)
                    if let vector = EmbeddingHelper.getVector(for: value) {
                        memory.embeddingData = EmbeddingHelper.serialize(vector)
                    }
                }

                try? context.save()
                print("🧠 [ReflectionManager]: Injected procedural skill memory into SwiftData database.")
            }

        } catch {
            print("🧠 [ReflectionManager]: Failed to generate skill reflection: \(error)")
        }
    }

    private func createSession<M: LanguageModel>(
        model: M,
        systemPrompt: String,
        orchestrator: AgentOrchestrator
    ) -> LanguageModelSession {
        let profile = ApexAgentProfile(
            instructions: systemPrompt,
            model: model,
            toolCallingMode: .disallowed,
            orchestrator: orchestrator,
            reasoningLevel: apexConfiguredReasoningLevel(),
            maxResponseTokens: apexConfiguredMaxResponseTokens()
        )
        return LanguageModelSession(profile: profile, history: Transcript(entries: []))
    }
}
