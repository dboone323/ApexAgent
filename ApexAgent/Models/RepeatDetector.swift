import Foundation

// MARK: - RepeatDetector: notice a bot going in circles (O1, port of OpenMausBot repeat-detector.ts)
//
// The same tool call, the same arguments, again and again in one turn is a
// loop — wasted tokens and, for state-changing tools, wasted actions. This
// detector is deliberately observational only: it counts repeated calls per
// thread and reports when a configured threshold is hit, so the caller can
// surface a warning or stop the turn. The human always keeps Stop.

struct RepeatCallCount: Equatable, Sendable {
    let count: Int
    /// Set exactly when the count lands on a configured threshold.
    let threshold: Int?
}

/// Builds the canonical call signature a repeat is keyed on.
enum RepeatCallKey {
    /// A tool call with no meaningful arguments (or whose arguments equal its
    /// own name) is not a repeat worth counting: "run_shell_command" five
    /// times may be five different commands.
    static func make(tool: String, arguments: String?) -> String? {
        guard let raw = arguments else { return nil }
        let normalized = raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized != tool else { return nil }
        return "\(tool):\(normalized)"
    }
}

/// Tracks repeated call signatures per thread. Keys are kept in explicit
/// least-recently-seen order (Swift's Dictionary, unlike JS Map, does not
/// preserve insertion order), so when the per-thread set fills, the
/// least-recently-seen signature falls out — matching bounded-memory LRU
/// semantics without retaining every unique command a long turn issued.
final class RepeatDetector: @unchecked Sendable {
    private struct ThreadState {
        var counts: [String: Int] = [:]
        var recency: [String] = []   // oldest first
    }

    private let lock = NSLock()
    private var states: [String: ThreadState] = [:]
    private let thresholds: [Int]
    private let maxKeysPerThread: Int

    init(thresholds: [Int] = [3, 5], maxKeysPerThread: Int = 256) {
        precondition(maxKeysPerThread >= 1, "maxKeysPerThread must be a positive integer")
        self.thresholds = thresholds.sorted()
        self.maxKeysPerThread = maxKeysPerThread
    }

    /// Count one call. `threshold` is non-nil exactly when the count lands on
    /// one of the configured thresholds.
    func record(thread: String, key: String) -> RepeatCallCount {
        lock.lock()
        defer { lock.unlock() }

        var state = states[thread] ?? ThreadState()

        // Move the key to the back of the recency list (most recently seen).
        state.recency.removeAll { $0 == key }
        if state.counts[key] == nil && state.recency.count >= maxKeysPerThread,
           let oldest = state.recency.first {
            // Full and this key is new: the least-recently-seen signature falls out.
            state.recency.removeFirst()
            state.counts.removeValue(forKey: oldest)
        }
        state.recency.append(key)

        let count = (state.counts[key] ?? 0) + 1
        state.counts[key] = count
        states[thread] = state

        let hit = thresholds.first(where: { $0 == count })
        return RepeatCallCount(count: count, threshold: hit)
    }

    /// The turn ended: a new turn starts its own count.
    func settle(thread: String) {
        lock.lock()
        defer { lock.unlock() }
        states.removeValue(forKey: thread)
    }

    /// Number of distinct active call signatures for a thread (test/inspection).
    func activeKeys(thread: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return states[thread]?.counts.count ?? 0
    }
}
