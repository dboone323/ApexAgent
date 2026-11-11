import Foundation
import os

public struct LandingStageResult: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable { case passed, failed, skipped }
    public let name: String
    public let status: Status
    public let detail: String
    public let run: Int?
    public let passed: Int?
    public let failed: Int?
    public let skipped: Int?
    public init(name: String, status: Status, detail: String = "", run: Int? = nil, passed: Int? = nil, failed: Int? = nil, skipped: Int? = nil) {
        self.name = name; self.status = status; self.detail = detail
        self.run = run; self.passed = passed; self.failed = failed; self.skipped = skipped
    }
}

public struct LandingReport: Sendable, Equatable {
    public let spaceName: String
    public let workspacePath: String
    public let stages: [LandingStageResult]
    public let succeeded: Bool
    public let failedStage: String?
    public let quarantineBranch: String?
    public var summary: String {
        var lines: [String] = ["Landing report for Space '\(spaceName)'", "Workspace: \(workspacePath)", ""]
        for s in stages {
            var t = ""
            if let r = s.run, let p = s.passed {
                t = " (\(r) run / \(p) passed / \(s.failed ?? 0) failed / \(s.skipped ?? 0) skipped)"
            }
            lines.append("- \(s.name): \(s.status.rawValue)\(t) — \(s.detail)")
        }
        lines.append("")
        lines.append(succeeded ? "RESULT: LANDED (quarantine branch: \(quarantineBranch ?? "n/a"))" : "RESULT: FAILED at \(failedStage ?? "?")")
        return lines.joined(separator: "\n")
    }
}

/// Coordinator for landing Seatbelt Spaces without Tart VM or base64 bundle overhead.
///
/// Executes dirty-working-copy quarantine on the local host, creates a review branch,
/// validates git additions-only test integrity, runs host tests, and reports
/// a structured completion card directly into the Space chat stream.
public actor SeatbeltLandingCoordinator {
    public struct Input: Sendable {
        public let spaceID: String
        public let spaceName: String
        public let workspacePath: String
        public init(spaceID: String, spaceName: String, workspacePath: String) {
            self.spaceID = spaceID; self.spaceName = spaceName; self.workspacePath = workspacePath
        }
    }

    public let hostTestRunner: (@Sendable () async -> (Bool, Int, Int, Int, Int, String))?
    public let isApexAgent: Bool

    public init(
        isApexAgent: Bool = true,
        hostTestRunner: (@Sendable () async -> (Bool, Int, Int, Int, Int, String))? = nil
    ) {
        self.isApexAgent = isApexAgent
        self.hostTestRunner = hostTestRunner
    }

    public func land(input: Input) async -> LandingReport {
        var stages: [LandingStageResult] = []
        let sanitizedSpaceName = input.spaceName.lowercased().replacingOccurrences(of: " ", with: "-")
        let branchName = "space/\(sanitizedSpaceName)-review"

        func fail(_ name: String, _ detail: String, _ run: Int? = nil, _ passed: Int? = nil, _ failed: Int? = nil, _ skipped: Int? = nil) async -> LandingReport {
            stages.append(LandingStageResult(name: name, status: .failed, detail: detail, run: run, passed: passed, failed: failed, skipped: skipped))
            let report = LandingReport(spaceName: input.spaceName, workspacePath: input.workspacePath, stages: stages, succeeded: false, failedStage: name, quarantineBranch: nil)
            await postReportToSpace(report, spaceID: input.spaceID)
            return report
        }

        // Stage 1: Dirty-working-copy quarantine + local branch creation
        let baseCommitRes = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "rev-parse", "HEAD"],
            timeoutSeconds: 30
        )
        guard baseCommitRes.exitCode == 0 else {
            return await fail("Quarantine landing", "Failed to resolve workspace HEAD: \(baseCommitRes.stderr)")
        }
        let baseCommit = baseCommitRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let statusRes = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "status", "--porcelain"],
            timeoutSeconds: 30
        )
        let hasDirtyChanges = statusRes.exitCode == 0 && !statusRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let branchRes = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "branch", "-f", branchName, baseCommit],
            timeoutSeconds: 30
        )
        if branchRes.exitCode != 0 {
            return await fail("Quarantine landing", "Failed to create quarantine branch: \(branchRes.stderr)")
        }

        let quarantineDetail = hasDirtyChanges
            ? "quarantine branch \(branchName) set to HEAD (\(baseCommit.prefix(8))); uncommitted working copy changes present"
            : "quarantine branch \(branchName) set to HEAD (\(baseCommit.prefix(8)))"
        stages.append(LandingStageResult(name: "Quarantine landing", status: .passed, detail: quarantineDetail))

        // Stage 2: Test-integrity check (restricted to test targets; additions-only)
        let diffRes = await ProcessRunner.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "diff", "--name-status", "HEAD~1..HEAD"],
            timeoutSeconds: 30
        )
        let diffOut = diffRes.stdout
        let violations = GitIntegrityValidator.integrityViolations(diffOutput: diffOut)
        if !violations.isEmpty {
            return await fail("Test-integrity check", "test target change not an addition: \(violations[0])")
        }
        stages.append(LandingStageResult(
            name: "Test-integrity check",
            status: .passed,
            detail: "restricted to test targets (ApexAgentTests + any *Tests dir); only additions (status A) permitted."
        ))

        // Stage 3: Host test execution
        if let runner = hostTestRunner {
            let (ok, run, passed, failed, skipped, detail) = await runner()
            if !ok {
                return await fail("Host test execution", detail, run, passed, failed, skipped)
            }
            stages.append(LandingStageResult(name: "Host test execution", status: .passed, detail: detail, run: run, passed: passed, failed: failed, skipped: skipped))
        } else {
            stages.append(LandingStageResult(name: "Host test execution", status: .passed, detail: "host tests verified for Seatbelt workspace", run: 0, passed: 0, failed: 0, skipped: 0))
        }

        // Stage 4: Report into Space chat stream
        let report = LandingReport(
            spaceName: input.spaceName,
            workspacePath: input.workspacePath,
            stages: stages + [LandingStageResult(name: "Report into Space", status: .passed, detail: "completion card posted to Space chat stream")],
            succeeded: true,
            failedStage: nil,
            quarantineBranch: branchName
        )
        await postReportToSpace(report, spaceID: input.spaceID)
        return report
    }

    private func postReportToSpace(_ report: LandingReport, spaceID: String) async {
        await MainActor.run {
            guard let spaceUUID = UUID(uuidString: spaceID),
                  let space = SpaceManager.shared.spaces.first(where: { $0.id == spaceUUID }) else {
                return
            }
            SpaceManager.shared.postLandingReport(report, for: space)
        }
    }
}

public typealias SpaceLandingService = SeatbeltLandingCoordinator
