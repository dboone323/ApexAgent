import Foundation
import ApexAgentCore

/// Shared helper that shells out to the macOS 27 `fm` CLI (`/usr/bin/fm`) to
/// run the on-device Apple Foundation Model. Reused by the App Intents so they
/// produce real answers without coupling to ApexAgentCore's session internals.
enum FMIntentSupport {
    /// Run `fm respond` and return the streamed text.
    /// - Parameters:
    ///   - prompt: the user prompt (instructions may be supplied separately).
    ///   - instructions: optional system instructions.
    ///   - model: `system` (on-device) or `pcc` (Private Cloud Compute).
    ///   - timeoutSeconds: max seconds to wait for `/usr/bin/fm` before terminating (default: 30s).
    static func runFM(
        prompt: String,
        instructions: String = "",
        model: String = "system",
        timeoutSeconds: TimeInterval = 30
    ) async throws -> String {
        guard let url = URL(string: "file:///usr/bin/fm") else {
            throw NSError(domain: "FMIntentSupport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "fm CLI not found at /usr/bin/fm."])
        }
        var args = ["respond", "--model", model, "--stream"]
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--instructions", instructions]
        }
        args.append(prompt)
        let processArgs = args

        return try await AFMCallSerializer.shared.withExclusiveLock {
            let process = Process()
            process.executableURL = url
            process.arguments = processArgs
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        var output = ""
                        for try await line in stdout.fileHandleForReading.bytes.lines {
                            if Task.isCancelled {
                                if process.isRunning { process.terminate() }
                                throw CancellationError()
                            }
                            output += line + "\n"
                        }
                        process.waitUntilExit()
                        if process.terminationStatus != 0, output.isEmpty {
                            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                            throw NSError(domain: "FMIntentSupport", code: -2,
                                          userInfo: [NSLocalizedDescriptionKey: "fm exited \(process.terminationStatus): \(err)"])
                        }
                        return output.trimmingCharacters(in: .whitespacesAndNewlines)
                    }

                    // Enforce bounded timeout so stalled CLI or dropped daemon XPC connection never hangs tests
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeoutSeconds))
                        if process.isRunning { process.terminate() }
                        throw NSError(
                            domain: "FMIntentSupport",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "fm CLI timed out after \(Int(timeoutSeconds)) seconds."]
                        )
                    }

                    guard let result = try await group.next() else {
                        throw NSError(domain: "FMIntentSupport", code: -2, userInfo: [NSLocalizedDescriptionKey: "fm CLI returned no output."])
                    }
                    group.cancelAll()
                    return result
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }
}
