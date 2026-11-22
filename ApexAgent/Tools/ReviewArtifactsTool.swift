import Foundation
import FoundationModels

// MARK: - Review Artifacts Tool (Issue #103, G3)

struct ReviewArtifactsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "review_artifacts"
    let description = """
    Independent reviewer/critic agent that verifies artifacts against request claims before work is called done. \
    Checks that every claim is supported by an artifact, checks for contradictions, and asserts required files exist. \
    Returns verdict (pass/fail) with cited findings (artifact + file/line location).
    """

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The original request description or task claims to verify.")
        var request: String

        @Guide(description: "Comma-separated list of artifact paths, if checking files on disk.")
        var artifactPaths: String?

        @Guide(description: "JSON array of claims with optional expectedPattern, requiredArtifactPath, and contradictionPattern.")
        var claimsJSON: String?

        @Guide(description: "JSON array of in-memory artifacts [{\"path\":\"...\",\"content\":\"...\"}] if not on disk.")
        var artifactsJSON: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let orch = await orchestrator.orchestrator
            let wsPath = await MainActor.run { orch.currentWorkspacePath }

            var requiredPaths: [String] = []
            if let paths = arguments.artifactPaths, !paths.isEmpty {
                requiredPaths = paths.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }

            var inMemoryArtifacts: [ReviewArtifact] = []
            if let json = arguments.artifactsJSON,
               let data = json.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in list {
                    if let path = item["path"] as? String,
                       let content = item["content"] as? String {
                        inMemoryArtifacts.append(ReviewArtifact(
                            id: (item["id"] as? String) ?? UUID().uuidString,
                            path: path,
                            content: content,
                            section: item["section"] as? String
                        ))
                    }
                }
            }

            var claims: [ReviewClaim] = []
            if let json = arguments.claimsJSON,
               let data = json.data(using: .utf8),
               let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                for item in list {
                    if let text = item["claimText"] as? String ?? item["claim"] as? String {
                        claims.append(ReviewClaim(
                            id: (item["id"] as? String) ?? UUID().uuidString,
                            claimText: text,
                            requiredArtifactPath: item["requiredArtifactPath"] as? String,
                            expectedPattern: item["expectedPattern"] as? String,
                            contradictionPattern: item["contradictionPattern"] as? String
                        ))
                    }
                }
            }

            let reviewReq = ReviewRequest(
                requestDescription: arguments.request,
                claims: claims,
                requiredArtifactPaths: requiredPaths,
                artifacts: inMemoryArtifacts,
                workspacePath: wsPath
            )

            let reviewer = ReviewerAgent()
            let report = await reviewer.review(request: reviewReq, recordToTrace: true)

            var outputLines: [String] = []
            outputLines.append("=== Reviewer / Critic Verdict: \(report.verdict.rawValue.uppercased()) ===")
            outputLines.append("Summary: \(report.summary)")
            if report.findings.isEmpty {
                outputLines.append("Findings: None. All claims supported by verified artifacts.")
            } else {
                outputLines.append("Findings (\(report.findings.count)):")
                for (idx, f) in report.findings.enumerated() {
                    outputLines.append("  [\(idx + 1)] [\(f.kind.rawValue)] \(f.location): \(f.reason)")
                }
            }

            return outputLines.joined(separator: "\n")
        }
    }
}
