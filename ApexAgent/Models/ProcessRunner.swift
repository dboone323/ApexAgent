import Foundation
import os

/// Host subprocess runner implementing pipe deadlock resistance and lifecycle management.
///
/// Designed during Deep Coverage Audit Batch 1 to prevent 64KB Darwin kernel pipe buffer
/// deadlocks via concurrent asynchronous pipe draining, combined with a SIGTERM/SIGKILL
/// watchdog escalation policy.
public enum ProcessRunner {

    private final class ProcessExecutionCoordinator: @unchecked Sendable {
        private struct State {
            var stdoutData = Data()
            var stderrData = Data()
            var stdoutFinished = false
            var stderrFinished = false
            var processFinished = false
            var isResumed = false
            var continuation: CheckedContinuation<Void, Never>?

            mutating func checkNormalCompletion() -> CheckedContinuation<Void, Never>? {
                if stdoutFinished && stderrFinished && processFinished && !isResumed {
                    isResumed = true
                    let c = continuation
                    continuation = nil
                    return c
                }
                return nil
            }

            mutating func forceCompletion() -> CheckedContinuation<Void, Never>? {
                if !isResumed {
                    isResumed = true
                    let c = continuation
                    continuation = nil
                    return c
                }
                return nil
            }
        }

        private let lock = OSAllocatedUnfairLock(initialState: State())

        func appendStdout(_ chunk: Data) {
            lock.withLock { $0.stdoutData.append(chunk) }
        }

        func appendStderr(_ chunk: Data) {
            lock.withLock { $0.stderrData.append(chunk) }
        }

        func finishStdout(processIsRunning: Bool) {
            let cont = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                state.stdoutFinished = true
                if !processIsRunning { state.processFinished = true }
                return state.checkNormalCompletion()
            }
            cont?.resume()
        }

        func finishStderr(processIsRunning: Bool) {
            let cont = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                state.stderrFinished = true
                if !processIsRunning { state.processFinished = true }
                return state.checkNormalCompletion()
            }
            cont?.resume()
        }

        func finishProcess() {
            let cont = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                state.processFinished = true
                return state.checkNormalCompletion()
            }
            cont?.resume()
        }

        func forceFinish() {
            let cont = lock.withLock { $0.forceCompletion() }
            cont?.resume()
        }

        func setContinuation(_ continuation: CheckedContinuation<Void, Never>) {
            let shouldResumeImmediately: Bool = lock.withLock { state in
                if (state.stdoutFinished && state.stderrFinished && state.processFinished) || state.isResumed {
                    state.isResumed = true
                    state.continuation = nil
                    return true
                } else {
                    state.continuation = continuation
                    return false
                }
            }
            if shouldResumeImmediately {
                continuation.resume()
            }
        }

        func results() -> (stdout: String, stderr: String) {
            lock.withLock { state in
                (String(data: state.stdoutData, encoding: .utf8) ?? "",
                 String(data: state.stderrData, encoding: .utf8) ?? "")
            }
        }
    }

    public static func runProcessSafely(
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

        let coordinator = ProcessExecutionCoordinator()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                coordinator.finishStdout(processIsRunning: process.isRunning)
            } else {
                coordinator.appendStdout(chunk)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                try? handle.close()
                coordinator.finishStderr(processIsRunning: process.isRunning)
            } else {
                coordinator.appendStderr(chunk)
            }
        }

        process.terminationHandler = { _ in
            coordinator.finishProcess()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            return (-1, "", error.localizedDescription)
        }

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(timeoutSeconds))
            } catch {
                return
            }

            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()

            coordinator.forceFinish()
        }
        defer { timeoutTask.cancel() }

        await withCheckedContinuation { continuation in
            coordinator.setContinuation(continuation)
        }

        timeoutTask.cancel()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()

        process.waitUntilExit()
        process.terminationHandler = nil

        let (stdout, stderr) = coordinator.results()
        return (process.terminationStatus, stdout, stderr)
    }
}
