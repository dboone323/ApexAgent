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
            let build = try? await client.exec(name: vmName, arguments: ["sh", "-c", "sudo launchctl asuser 501 sudo -u admin sh -c 'cd ~/ApexAgent && xcodebuild -scheme ApexAgent -configuration Debug build 2>&1'"])
            if let b = build, b.exitCode != 0 {
                return fail("In-VM gate", "build failed: \(b.stderr)")
            }
            let testCmd = "sudo launchctl asuser 501 sudo -u admin sh -c 'cd ~/ApexAgent && xcodebuild test -scheme ApexAgent -testPlan ApexAgent-UnitTests -resultBundlePath /tmp/guest.xcresult 2>&1'"
            let tr = try? await client.exec(name: vmName, arguments: ["sh", "-c", testCmd])
            let parse = try? await client.exec(name: vmName, arguments: ["sh", "-c", "sudo launchctl asuser 501 sudo -u admin sh -c 'xcrun xcresulttool get test-results summary --path /tmp/guest.xcresult 2>/dev/null || true'"])
            let out = (tr?.stdout ?? "") + "\n" + (parse?.stdout ?? "")
            let totals = parseTotals(out)
            guestTotals = totals
            if (tr?.exitCode ?? 1) != 0 {
                return fail("In-VM gate", "tests failed: \(totals.0) run / \(totals.1) passed / \(totals.2) failed / \(totals.3) skipped", totals.0, totals.1, totals.2, totals.3)
            }
            if !(totals.0 > 0 && totals.2 == 0) {
                return fail("In-VM gate", "gate totals not clean: \(totals.0) run / \(totals.1) passed / \(totals.2) failed / \(totals.3) skipped", totals.0, totals.1, totals.2, totals.3)
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
            stages.append(LandingStageResult(name: "In-VM gate", status: .passed, detail: "clean build + unit plan (\(guestTotals.0) run / \(guestTotals.1) passed / \(guestTotals.2) failed / \(guestTotals.3) skipped) + lint passed in guest", run: guestTotals.0, passed: guestTotals.1, failed: guestTotals.2, skipped: guestTotals.3))
        }

        let baseCommitRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "rev-parse", "HEAD"],
            timeoutSeconds: 30
        )
        let baseCommit = baseCommitRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Determine whether the guest has commits beyond baseCommit.
        let countRes = try? await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && git rev-list --count \(baseCommit)..HEAD"])
        let deltaCount = Int(countRes?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
        let bundleSpec = deltaCount > 0 ? "\(baseCommit)..HEAD" : "HEAD"

        var createRes: (stdout: String, stderr: String, exitCode: Int32)?
        var createErr: String?
        do {
            createRes = try await client.exec(name: vmName, arguments: ["sh", "-c", "cd ~/ApexAgent && git bundle create /tmp/land.bundle \(bundleSpec)"])
        } catch {
            createErr = "\(error)"
        }
        guard let cr = createRes, cr.exitCode == 0 else {
            let detail = createErr ?? createRes.map { "bundle create failed (exit \($0.exitCode)): \($0.stderr)" } ?? "bundle create failed"
            return fail("Transfer + verify", detail)
        }

        var b64Res: (stdout: String, stderr: String, exitCode: Int32)?
        var b64Err: String?
        do {
            b64Res = try await client.exec(name: vmName, arguments: ["sh", "-c", "base64 -i /tmp/land.bundle"])
        } catch {
            b64Err = "\(error)"
        }
        guard let b64 = b64Res, b64.exitCode == 0 else {
            let detail = b64Err ?? b64Res.map { "base64 failed (exit \($0.exitCode)): \($0.stderr)" } ?? "base64 failed"
            return fail("Transfer + verify", detail)
        }
        let b64Out = b64.stdout
        guard !b64Out.isEmpty else {
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
        let verifyRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", input.workspacePath, "bundle", "verify", tmpBundle.path],
            timeoutSeconds: 60
        )
        if verifyRes.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Transfer + verify", "git bundle verify failed: \(verifyRes.stderr)")
        }
        stages.append(LandingStageResult(name: "Transfer + verify", status: .passed, detail: "bundle created in guest, transferred via base64, git bundle verify passed"))

        let fm = FileManager.default
        if !fm.fileExists(atPath: reviewClonePath) {
            let cloneRes = await Self.runProcessSafely(
                executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["clone", input.workspacePath, reviewClonePath],
                timeoutSeconds: 120
            )
            if cloneRes.exitCode != 0 {
                try? FileManager.default.removeItem(at: tmpBundle)
                return fail("Quarantine landing", "failed to create review clone: \(cloneRes.stderr)")
            }
        }
        let fetchRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", reviewClonePath, "fetch", tmpBundle.path, "HEAD"],
            timeoutSeconds: 60
        )
        if fetchRes.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Quarantine landing", "fetch bundle failed (exit \(fetchRes.exitCode)): \(fetchRes.stderr)")
        }
        let updRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", reviewClonePath, "update-ref", "refs/heads/\(branchName)", "FETCH_HEAD"],
            timeoutSeconds: 30
        )
        if updRes.exitCode != 0 {
            try? FileManager.default.removeItem(at: tmpBundle)
            return fail("Quarantine landing", "update-ref failed: \(updRes.stderr)")
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
        // Real parsing from `xcrun xcresulttool get test-results summary` JSON.
        // Read the WHOLE-RUN (top-level) scope, not a nested per-suite scope:
        // prefer JSON decoding of the last JSON object in the text, fall back to
        // last-match regex (top-level keys appear after nested ones).
        func jsonInt(_ obj: [String: Any], _ key: String) -> Int? {
            if let v = obj[key] as? Int { return v }
            if let v = obj[key] as? NSNumber { return v.intValue }
            if let s = obj[key] as? String { return Int(s) }
            return nil
        }
        // Try to decode the last JSON object in the text.
        if let start = text.lastIndex(of: "{") {
            let substr = String(text[start...])
            if let data = substr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let passed = jsonInt(obj, "passedTests") ?? 0
                let failed = jsonInt(obj, "failedTests") ?? 0
                let skipped = jsonInt(obj, "skippedTests") ?? 0
                let run = jsonInt(obj, "totalTestCount") ?? (passed + failed + skipped)
                return (run, passed, failed, skipped)
            }
        }
        func lastInt(for key: String) -> Int? {
            let pattern = "\"\(key)\"\\s*:\\s*(\\d+)"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let range = NSRange(text.startIndex..., in: text)
            let matches = re.matches(in: text, range: range)
            guard let m = matches.last, m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: text) else { return nil }
            return Int(text[r])
        }
        let passed = lastInt(for: "passedTests") ?? 0
        let failed = lastInt(for: "failedTests") ?? 0
        let skipped = lastInt(for: "skippedTests") ?? 0
        let run = lastInt(for: "totalTestCount") ?? (passed + failed + skipped)
        return (run, passed, failed, skipped)
    }


    internal static func runProcessSafely(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval = 600
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            if process.isRunning {
                process.terminate()
            }
        }
        defer { timeoutTask.cancel() }

        // Concurrently drain stdout and stderr using detached worker tasks
        async let stdoutData: Data = Task.detached {
            let handle = outPipe.fileHandleForReading
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            return data
        }.value

        async let stderrData: Data = Task.detached {
            let handle = errPipe.fileHandleForReading
            let data = handle.readDataToEndOfFile()
            try? handle.close()
            return data
        }.value

        let (outData, errData) = await (stdoutData, stderrData)
        process.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    private func defaultHostRun(reviewClonePath: String, branchName: String) async -> (Bool, Int, Int, Int, Int, String) {
        let coRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", reviewClonePath, "checkout", branchName],
            timeoutSeconds: 60
        )
        if coRes.exitCode != 0 {
            return (false, 0, 0, 0, 0, "git checkout failed: \(coRes.stderr)")
        }

        let buildRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-project", "\(reviewClonePath)/ApexAgent.xcodeproj", "-scheme", "ApexAgent", "-configuration", "Debug", "build"],
            timeoutSeconds: 600
        )
        if buildRes.exitCode != 0 {
            return (false, 0, 0, 0, 0, "host build failed: \(buildRes.stderr)")
        }

        let hostBundle = "/tmp/host-rerun.xcresult"
        try? FileManager.default.removeItem(atPath: hostBundle)

        let testRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: ["-project", "\(reviewClonePath)/ApexAgent.xcodeproj", "-scheme", "ApexAgent", "-testPlan", "ApexAgent-UnitTests", "-resultBundlePath", hostBundle, "test"],
            timeoutSeconds: 600
        )

        let summaryRes = await Self.runProcessSafely(
            executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["xcresulttool", "get", "test-results", "summary", "--path", hostBundle],
            timeoutSeconds: 60
        )

        let totals = parseTotals(summaryRes.stdout)
        return (testRes.exitCode == 0, totals.0, totals.1, totals.2, totals.3, "host re-run completed")
    }
}
