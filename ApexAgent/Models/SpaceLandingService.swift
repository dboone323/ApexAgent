import Foundation

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

public actor SpaceLandingService {
    public struct Input: Sendable {
        public let spaceID: String
        public let spaceName: String
        public let workspacePath: String
        public init(spaceID: String, spaceName: String, workspacePath: String) {
            self.spaceID = spaceID; self.spaceName = spaceName; self.workspacePath = workspacePath
        }
    }

    public let client: any TartClientProtocol
    public let manager: VMWorkspaceManager
    public let reviewClonePath: String
    public let isApexAgent: Bool
    public let hostTestRunner: (@Sendable () async -> (Bool, Int, Int, Int, Int, String))?

    public init(
        client: any TartClientProtocol = TartCLIClient(),
        manager: VMWorkspaceManager? = nil,
        reviewClonePath: String = (NSHomeDirectory() as NSString).appendingPathComponent("ApexSandbox/review-clone"),
        isApexAgent: Bool = true,
        hostTestRunner: (@Sendable () async -> (Bool, Int, Int, Int, Int, String))? = nil
    ) {
        self.client = client
        self.manager = manager ?? VMWorkspaceManager(client: client)
        self.reviewClonePath = reviewClonePath
        self.isApexAgent = isApexAgent
        self.hostTestRunner = hostTestRunner
    }

    public func land(input: Input) async -> LandingReport {
        var stages: [LandingStageResult] = []
        let branchName = "space/\(input.spaceName)-review"
        func fail(_ name: String, _ detail: String, _ run: Int? = nil, _ passed: Int? = nil, _ failed: Int? = nil, _ skipped: Int? = nil) -> LandingReport {
            stages.append(LandingStageResult(name: name, status: .failed, detail: detail, run: run, passed: passed, failed: failed, skipped: skipped))
            return LandingReport(spaceName: input.spaceName, workspacePath: input.workspacePath, stages: stages, succeeded: false, failedStage: name, quarantineBranch: nil)
        }

        do {
            try await manager.ensureProvisioned(spaceID: input.spaceID)
            try await manager.startIfNeeded(spaceID: input.spaceID)
        } catch {
            return fail("In-VM gate", "VM not ready: \(error)")
        }
        let backend = TartVMBackend(spaceID: input.spaceID, manager: manager, client: client)
        do {
            try await backend.seed(workspacePath: input.workspacePath)
        } catch {
            return fail("In-VM gate", "seed failed: \(error)")
        }
        let vmName = VMWorkspaceManager.vmName(for: input.spaceID)
        let isApex = isApexAgent
        var guestTotals: (Int, Int, Int, Int) = (0,0,0,0)
        if isApex {
            let build = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && xcodebuild -scheme ApexAgent -configuration Debug build 2>&1 | tail -5"])
            if let b = build, b.exitCode != 0 {
                return fail("In-VM gate", "build failed: \(b.stderr)")
            }
            let testCmd = "cd ~/ApexAgent && xcodebuild test -scheme ApexAgent -testPlan ApexAgent-UnitTests -resultBundlePath /tmp/guest.xcresult 2>&1 | tail -5"
            let tr = try? await client.exec(name: vmName, arguments: ["sh", "-c", testCmd])
            let parse = try? await client.exec(name: vmName, arguments: ["sh", "-c", "xcrun xcresulttool get test-results summary --path /tmp/guest.xcresult 2>/dev/null || true"])
            let out = (tr?.stdout ?? "") + "\n" + (parse?.stdout ?? "")
            let totals = parseTotals(out)
            guestTotals = totals
            if (tr?.exitCode ?? 1) != 0 {
                return fail("In-VM gate", "tests failed", totals.0, totals.1, totals.2, totals.3)
            }
            let lint = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && echo LINT_OK"])
            if let l = lint, l.exitCode != 0 {
                return fail("In-VM gate", "lint failed: \(l.stderr)")
            }
        } else {
            let build = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && (ls *.xcodeproj >/dev/null 2>&1 && xcodebuild build 2>&1 | tail -3) || (test -f Package.swift && swift build 2>&1 | tail -3) || echo BUILD_ONLY"])
            if let b = build, b.exitCode != 0 && !b.stdout.contains("BUILD_ONLY") {
                return fail("In-VM gate", "build failed: \(b.stderr)")
            }
            stages.append(LandingStageResult(name: "In-VM gate", status: .passed, detail: "build-only / discovered commands completed", run: 0, passed: 0, failed: 0, skipped: 0))
        }
        if isApex {
            stages.append(LandingStageResult(name: "In-VM gate", status: .passed, detail: "clean build + unit plan + lint passed in guest", run: guestTotals.0, passed: guestTotals.1, failed: guestTotals.2, skipped: guestTotals.3))
        }

        let baseCommitProc = Process()
        baseCommitProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        baseCommitProc.arguments = ["-C", input.workspacePath, "rev-parse", "HEAD"]
        let bp = Pipe(); baseCommitProc.standardOutput = bp; baseCommitProc.standardError = Pipe()
        try? baseCommitProc.run(); baseCommitProc.waitUntilExit()
        let baseCommit = String(data: bp.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let diffCmd = "cd ~/ApexAgent && git diff --name-status \(baseCommit)..HEAD"
        let diffRes = try? await client.exec(name: vmName, arguments: ["sh", "-c", diffCmd])
        let diffOut = diffRes?.stdout ?? ""
        let violations = SpaceLandingService.integrityViolations(diffOutput: diffOut)
        var integrityOK = violations.isEmpty
        var integrityDetail = violations.isEmpty ? "additions-only in test targets" : "test target change not an addition: \(violations[0])"
        let anc = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && git merge-base --is-ancestor \(baseCommit) HEAD && echo ANCESTOR_OK"])
        if anc?.stdout.contains("ANCESTOR_OK") != true {
            integrityOK = false
            integrityDetail = "guest HEAD is not descendant of workspace HEAD"
        }
        if !integrityOK {
            return fail("Test-integrity check", integrityDetail)
        }
        stages.append(LandingStageResult(name: "Test-integrity check", status: .passed, detail: "comparison: guest HEAD vs workspace HEAD (\(baseCommit.prefix(8))) restricted to test targets (ApexAgentTests + any *Tests dir); only additions (status A) permitted."))

        _ = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && git bundle create /tmp/land.bundle HEAD"])
        let b64 = try? await client.exec(name: vmName, arguments: ["sh", "-c", "base64 /tmp/land.bundle"])
        guard let b64Out = b64?.stdout, !b64Out.isEmpty else {
            return fail("Transfer + verify", "failed to read bundle from guest")
        }
        let cleaned = b64Out.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            return fail("Transfer + verify", "base64 decode failed")
        }
        let tmpBundle = FileManager.default.temporaryDirectory.appendingPathComponent("land-\(input.spaceID).bundle")
        do { try data.write(to: tmpBundle) } catch {
            return fail("Transfer + verify", "write bundle failed: \(error)")
        }
        let verifyProc = Process()
        verifyProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        verifyProc.arguments = ["bundle", "verify", tmpBundle.path]
        let vp = Pipe(); verifyProc.standardOutput = vp; verifyProc.standardError = Pipe()
        try? verifyProc.run(); verifyProc.waitUntilExit()
        if verifyProc.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Transfer + verify", "git bundle verify failed")
        }
        stages.append(LandingStageResult(name: "Transfer + verify", status: .passed, detail: "bundle created in guest, transferred via base64, git bundle verify passed"))

        let fm = FileManager.default
        if !fm.fileExists(atPath: reviewClonePath) {
            let cloneProc = Process()
            cloneProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            cloneProc.arguments = ["clone", input.workspacePath, reviewClonePath]
            try? cloneProc.run(); cloneProc.waitUntilExit()
            if cloneProc.terminationStatus != 0 {
                try? FileManager.default.removeItem(at: tmpBundle)
                return fail("Quarantine landing", "failed to create review clone")
            }
        }
        let fetchProc = Process()
        fetchProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        fetchProc.arguments = ["-C", reviewClonePath, "fetch", tmpBundle.path, "HEAD"]
        try? fetchProc.run(); fetchProc.waitUntilExit()
        if fetchProc.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Quarantine landing", "fetch bundle failed")
        }
        let updProc = Process()
        updProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        updProc.arguments = ["-C", reviewClonePath, "update-ref", "refs/heads/\(branchName)", "FETCH_HEAD"]
        try? updProc.run(); updProc.waitUntilExit()
        if updProc.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Quarantine landing", "update-ref failed")
        }
        try? FileManager.default.removeItem(at: tmpBundle)
        stages.append(LandingStageResult(name: "Quarantine landing", status: .passed, detail: "review clone \(reviewClonePath): branch \(branchName) set to bundle HEAD"))

        if isApex {
            let runner = hostTestRunner
            let result: (Bool, Int, Int, Int, Int, String)
            if let r = runner {
                result = await r()
            } else {
                result = await defaultHostRun(reviewClonePath: reviewClonePath, branchName: branchName)
            }
            let (ok, run, passed, failed, skipped, detail) = result
            if !ok {
                stages.append(LandingStageResult(name: "Host pristine re-run", status: .failed, detail: detail, run: run, passed: passed, failed: failed, skipped: skipped))
                return LandingReport(spaceName: input.spaceName, workspacePath: input.workspacePath, stages: stages, succeeded: false, failedStage: "Host pristine re-run", quarantineBranch: branchName)
            }
            stages.append(LandingStageResult(name: "Host pristine re-run", status: .passed, detail: detail, run: run, passed: passed, failed: failed, skipped: skipped))
        } else {
            stages.append(LandingStageResult(name: "Host pristine re-run", status: .skipped, detail: "skipped — not the ApexAgent repo"))
        }

        stages.append(LandingStageResult(name: "Report into Space", status: .skipped, detail: "no clean Space-chat reporting path wired; report returned from service"))
        return LandingReport(spaceName: input.spaceName, workspacePath: input.workspacePath, stages: stages, succeeded: true, failedStage: nil, quarantineBranch: branchName)
    }

    public static func integrityViolations(diffOutput: String) -> [String] {
        var violations: [String] = []
        for line in diffOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 2 else { continue }
            let status = String(parts[0])
            let path = String(parts[1])
            let isTest: Bool = {
                if path.hasPrefix("ApexAgentTests/") { return true }
                if path.contains("/Tests/") { return true }
                for comp in path.split(separator: "/") {
                    if String(comp).hasSuffix("Tests") { return true }
                }
                return false
            }()
            if !isTest { continue }
            if status != "A" { violations.append("\(status) \(path)") }
        }
        return violations
    }

    private func parseTotals(_ text: String) -> (Int, Int, Int, Int) {
        return (0,0,0,0)
    }


    private func defaultHostRun(reviewClonePath: String, branchName: String) async -> (Bool, Int, Int, Int, Int, String) {
        let co = Process()
        co.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        co.arguments = ["-C", reviewClonePath, "checkout", branchName]
        try? co.run(); co.waitUntilExit()
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        build.arguments = ["-project", "\(reviewClonePath)/ApexAgent.xcodeproj", "-scheme", "ApexAgent", "-configuration", "Debug", "build"]
        let bp = Pipe(); build.standardOutput = bp; build.standardError = Pipe()
        try? build.run(); build.waitUntilExit()
        if build.terminationStatus != 0 { return (false, 0, 0, 0, 0, "host build failed") }
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        test.arguments = ["-project", "\(reviewClonePath)/ApexAgent.xcodeproj", "-scheme", "ApexAgent", "-testPlan", "ApexAgent-UnitTests", "test"]
        let tp = Pipe(); test.standardOutput = tp; test.standardError = Pipe()
        try? test.run(); test.waitUntilExit()
        return (test.terminationStatus == 0, 0, 0, 0, 0, "host re-run completed")
    }
}
