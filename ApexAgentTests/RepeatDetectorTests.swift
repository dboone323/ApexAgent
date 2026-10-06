import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - O1: RepeatDetector

@Suite("RepeatDetectorTests")
struct RepeatDetectorTests {

    @Test func callKeyNormalizesWhitespace() {
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "  echo   hi  ")
            == "run_shell_command:echo hi")
    }

    @Test func callKeyNilForMissingOrBareArgs() {
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: nil) == nil)
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "") == nil)
        #expect(RepeatCallKey.make(tool: "run_shell_command", arguments: "run_shell_command") == nil)
    }

    @Test func recordHitsConfiguredThreshold() {
        let detector = RepeatDetector(thresholds: [3, 5])
        let key = RepeatCallKey.make(tool: "web_search", arguments: "query: apex")!
        for n in 1...5 {
            let result = detector.record(thread: "t1", key: key)
            if n == 3 { #expect(result.threshold == 3) }
            if n == 5 { #expect(result.threshold == 5) }
        }
        #expect(detector.activeKeys(thread: "t1") == 1)
    }

    @Test func threadsAreIndependent() {
        let detector = RepeatDetector(thresholds: [3])
        let key = RepeatCallKey.make(tool: "read_file", arguments: "/a")!
        for _ in 1...3 { _ = detector.record(thread: "t1", key: key) }
        _ = detector.record(thread: "t2", key: key)
        #expect(detector.activeKeys(thread: "t1") == 1)
        #expect(detector.activeKeys(thread: "t2") == 1)
    }

    @Test func settleResetsTurnCount() {
        let detector = RepeatDetector(thresholds: [3])
        let key = RepeatCallKey.make(tool: "run_shell_command", arguments: "git status")!
        _ = detector.record(thread: "t", key: key)
        let result = detector.record(thread: "t", key: key)
        #expect(result.threshold == nil)
        detector.settle(thread: "t")
        _ = detector.record(thread: "t", key: key)
        let after = detector.record(thread: "t", key: key)
        #expect(after.threshold == nil) // count restarted at 1,2
    }

    @Test func lruBoundsKeysPerThread() {
        let detector = RepeatDetector(thresholds: [10], maxKeysPerThread: 3)
        for i in 0..<5 {
            _ = detector.record(thread: "t", key: "k\(i)")
        }
        // "k0" was evicted; it now counts from 1 again
        let k0 = detector.record(thread: "t", key: "k0")
        #expect(k0.count == 1)
    }
}
