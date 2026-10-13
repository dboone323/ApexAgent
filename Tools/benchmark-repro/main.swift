// benchmark-repro — measures `respond(to:)` latency on a freshly created
// on-device LanguageModelSession. Session construction mirrors the profile-based
// pattern in AgentSessionCoordinator (LanguageModelSession.DynamicProfile +
// Transcript history), not the non-existent `LanguageModelSession.Configuration`
// API flagged by AUDIT_2026-09-28 §3.1.
import Foundation
import FoundationModels

struct BenchmarkProfile: LanguageModelSession.DynamicProfile {
    var body: some LanguageModelSession.DynamicProfile {
        LanguageModelSession.Profile {
            Instructions("You are a concise benchmark agent.")
        }
        .model(SystemLanguageModel.default)
    }
}

@main
struct BenchmarkRepro {
    static func main() async {
        let session = LanguageModelSession(
            profile: BenchmarkProfile(),
            history: Transcript(entries: [])
        )
        session.prewarm()

        print("Starting respond(to:) at", Date())
        let start = Date()
        do {
            let response = try await session.respond(to: "What is a Swift closure in one sentence?")
            let elapsed = Date().timeIntervalSince(start)
            print("respond finished in \(elapsed)s: \(response.content)")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            print("respond failed after \(elapsed)s: \(error)")
        }
    }
}
