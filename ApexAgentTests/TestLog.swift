import Foundation

/// Non-throwing, serialized append-only per-test log helper.
enum TestLog {
    /// Candidate (1): repo `build/test-logs/`. Resolved from this source file's location so it
    /// is stable regardless of the test host's working directory.
    static let logDir: URL = {
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("build/test-logs", isDirectory: true)
    }()

    private static let queue = DispatchQueue(label: "com.apexagent.testlog", qos: .utility)

    static func append(test: String, phase: String, message: String) {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
                let file = logDir.appendingPathComponent("\(test).log")
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss.SSS"
                let ts = formatter.string(from: Date())
                let line = "\(ts) [\(phase)] \(message)\n"
                if FileManager.default.fileExists(atPath: file.path) {
                    let handle = try FileHandle(forWritingTo: file)
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try handle.close()
                } else {
                    try line.write(to: file, atomically: false, encoding: .utf8)
                }
            } catch {
                print("TestLog: failed to append (test=\(test), phase=\(phase)): \(error)")
            }
        }
    }

    static func beginRun(test: String, runID: String) {
        let iso = ISO8601DateFormatter().string(from: Date())
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
                let file = logDir.appendingPathComponent("\(test).log")
                let line = "=== RUN \(iso) \(runID) ===\n"
                if FileManager.default.fileExists(atPath: file.path) {
                    let handle = try FileHandle(forWritingTo: file)
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    try handle.close()
                } else {
                    try line.write(to: file, atomically: false, encoding: .utf8)
                }
            } catch {
                print("TestLog: failed to beginRun (test=\(test)): \(error)")
            }
        }
    }
}
