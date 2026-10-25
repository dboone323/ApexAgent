import Testing
import Foundation

struct TestLogTests {
    private func logFile(_ test: String) -> URL {
        // Mirror TestLog.logDir resolution.
        let sourceFile = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFile.deletingLastPathComponent().deletingLastPathComponent()
        return repoRoot.appendingPathComponent("build/test-logs").appendingPathComponent("\(test).log")
    }

    @Test func appendCreatesFileAndWritesLine() throws {
        let name = "TestLogTests-appendCreates-\(UUID().uuidString)"
        let file = logFile(name)
        try? FileManager.default.removeItem(at: file)
        TestLog.append(test: name, phase: "phase1", message: "hello")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("[phase1] hello"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func secondAppendDoesNotOverwrite() throws {
        let name = "TestLogTests-secondAppend-\(UUID().uuidString)"
        let file = logFile(name)
        try? FileManager.default.removeItem(at: file)
        TestLog.append(test: name, phase: "a", message: "first")
        TestLog.append(test: name, phase: "b", message: "second")
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("[a] first"))
        #expect(content.contains("[b] second"))
        // both in order
        let lines = content.split(separator: "\n")
        #expect(lines.count >= 2)
        #expect(String(lines[0]).contains("first"))
        #expect(String(lines[1]).contains("second"))
        try? FileManager.default.removeItem(at: file)
    }

    @Test func beginRunWritesHeader() throws {
        let name = "TestLogTests-beginRun-\(UUID().uuidString)"
        let file = logFile(name)
        try? FileManager.default.removeItem(at: file)
        TestLog.beginRun(test: name, runID: "run-42")
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("=== RUN"))
        #expect(content.contains("run-42"))
        try? FileManager.default.removeItem(at: file)
    }
}
