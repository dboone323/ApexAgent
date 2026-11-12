import Foundation
import Darwin

// MARK: - Long Run Step Executor (Issue #77)

public enum LongRunStepError: Error, LocalizedError, Sendable, Equatable {
    case commandFailed(exitCode: Int32, stdout: String, stderr: String)
    case fileVerificationFailed(reason: String)
    case missingParameter(String)
    case deliberateFailure(attempt: Int, remainingFails: Int)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let out, let err):
            return "Command exited with status \(code). Output: '\(out)'. Error: '\(err)'"
        case .fileVerificationFailed(let reason):
            return "File verification failed: \(reason)"
        case .missingParameter(let param):
            return "Missing required parameter: '\(param)'"
        case .deliberateFailure(let attempt, let remaining):
            return "Deliberate step failure (attempt \(attempt), \(remaining) remaining before success)"
        case .timeout:
            return "Step execution timed out"
        }
    }
}

/// Actor executing individual steps with real functional operations.
public actor LongRunStepExecutor {
    public static let shared = LongRunStepExecutor()

    public init() {}

    /// Result produced by step execution.
    public struct StepResult: Sendable {
        public let output: String
        public let tokensUsed: Int
        public let updatedSharedState: [String: String]

        public init(output: String, tokensUsed: Int, updatedSharedState: [String: String] = [:]) {
            self.output = output
            self.tokensUsed = tokensUsed
            self.updatedSharedState = updatedSharedState
        }
    }

    /// Executes the specified step spec.
    public func execute(
        step: LongRunStepSpec,
        currentAttempt: Int,
        sharedState: [String: String]
    ) async throws -> StepResult {
        var state = sharedState

        switch step.kind {
        case .shellCommand:
            guard let cmd = step.inputPayload["command"] else {
                throw LongRunStepError.missingParameter("command")
            }
            let res = try await runShell(command: cmd)
            let tokens = estimateTokens(text: cmd + res.stdout)
            return StepResult(output: res.stdout, tokensUsed: max(tokens, step.estimatedTokens), updatedSharedState: state)

        case .fileWrite:
            guard let path = step.inputPayload["path"],
                  let content = step.inputPayload["content"] else {
                throw LongRunStepError.missingParameter("path or content")
            }
            let url = URL(fileURLWithPath: path)
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
            let tokens = estimateTokens(text: content)
            state["last_written_file"] = path
            return StepResult(output: "Wrote \(content.utf8.count) bytes to \(path)", tokensUsed: tokens, updatedSharedState: state)

        case .fileVerify:
            guard let path = step.inputPayload["path"] else {
                throw LongRunStepError.missingParameter("path")
            }
            let fm = FileManager.default
            guard fm.fileExists(atPath: path) else {
                throw LongRunStepError.fileVerificationFailed(reason: "File does not exist at \(path)")
            }
            if let containsStr = step.inputPayload["contains"] {
                let content = try String(contentsOfFile: path, encoding: .utf8)
                guard content.contains(containsStr) else {
                    throw LongRunStepError.fileVerificationFailed(reason: "File does not contain expected substring: '\(containsStr)'")
                }
            }
            return StepResult(output: "File verified at \(path)", tokensUsed: 10, updatedSharedState: state)

        case .tokenProcessing:
            let text = step.inputPayload["text"] ?? "ApexAgent standard token simulation payload"
            let mult = Int(step.inputPayload["multiplier"] ?? "1") ?? 1
            let baseTokens = max(1, estimateTokens(text: text))
            let totalTokens = baseTokens * mult
            return StepResult(output: "Processed \(text.count) characters (\(totalTokens) tokens)", tokensUsed: totalTokens, updatedSharedState: state)

        case .sleepDelay:
            let seconds = Double(step.inputPayload["seconds"] ?? "0.5") ?? 0.5
            let ns = UInt64(seconds * 1_000_000_000)
            try await Task.sleep(nanoseconds: ns)
            return StepResult(output: "Slept \(seconds) seconds", tokensUsed: 5, updatedSharedState: state)

        case .deterministicFailThenSucceed:
            let failAttempts = Int(step.inputPayload["failAttempts"] ?? "2") ?? 2
            if currentAttempt <= failAttempts {
                throw LongRunStepError.deliberateFailure(attempt: currentAttempt, remainingFails: failAttempts - currentAttempt)
            }
            let successOut = step.inputPayload["successOutput"] ?? "Step succeeded after \(failAttempts) retries"
            return StepResult(output: successOut, tokensUsed: 15, updatedSharedState: state)
        }
    }

    /// Runs a shell command via `/bin/zsh -c`.
    private func runShell(command: String) async throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let outStr = (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let errStr = (String(data: errData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0 {
            throw LongRunStepError.commandFailed(exitCode: process.terminationStatus, stdout: outStr, stderr: errStr)
        }
        return (outStr, errStr)
    }

    /// Real token estimation based on character and whitespace heuristics (~4 chars/token).
    private func estimateTokens(text: String) -> Int {
        if text.isEmpty { return 0 }
        let words = text.split { $0.isWhitespace || $0.isPunctuation }
        let charTokenEstimate = max(1, text.count / 4)
        return max(words.count, charTokenEstimate)
    }
}
