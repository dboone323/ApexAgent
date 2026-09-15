import Foundation

/// Shared helper that shells out to the macOS 27 `fm` CLI (`/usr/bin/fm`) to
/// run the on-device Apple Foundation Model. Reused by the App Intents so they
/// produce real answers without coupling to ApexAgentCore's session internals.
enum FMIntentSupport {
    /// Run `fm respond` and return the streamed text.
    /// - Parameters:
    ///   - prompt: the user prompt (instructions may be supplied separately).
    ///   - model: `system` (on-device) or `pcc` (Private Cloud Compute).
    static func runFM(prompt: String, instructions: String = "", model: String = "system") async throws -> String {
        guard let url = URL(string: "file:///usr/bin/fm") else {
            throw NSError(domain: "FMIntentSupport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "fm CLI not found at /usr/bin/fm."])
        }
        var args = ["respond", "--model", model, "--stream"]
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--instructions", instructions]
        }
        args.append(prompt)

        let process = Process()
        process.executableURL = url
        process.arguments = args
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        return try await withTaskCancellationHandler {
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
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
