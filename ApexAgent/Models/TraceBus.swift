import Foundation
import Observation

@Observable
final class TraceBus: @unchecked Sendable {
    static let shared = TraceBus()

    private(set) var events: [TraceEvent] = []
    private var continuations: [UUID: AsyncStream<TraceEvent>.Continuation] = [:]
    private let maxEvents: Int
    private let queue = DispatchQueue(label: "com.apexagent.tracebus", attributes: .concurrent)

    /// Injectable capacity so tests can run against an isolated instance;
    /// `shared` keeps the production default of 400.
    init(maxEvents: Int = 400) {
        self.maxEvents = maxEvents
    }

    func append(_ event: TraceEvent) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if self.events.count >= self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents + 1)
            }
            self.events.append(event)
            for continuation in self.continuations.values {
                continuation.yield(event)
            }
        }
    }

    public func eventStream() -> AsyncStream<TraceEvent> {
        AsyncStream { continuation in
            let id = UUID()
            queue.async(flags: .barrier) {
                self.continuations[id] = continuation
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                guard let self else { return }
                self.queue.async(flags: .barrier) {
                    self.continuations.removeValue(forKey: id)
                }
            }
        }
    }

    public func stream(forCategory category: String) -> AsyncStream<TraceEvent> {
        let baseStream = eventStream()
        return AsyncStream { continuation in
            let task = Task {
                for await event in baseStream {
                    if event.category == category {
                        continuation.yield(event)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    func recentEvents(limit: Int = 50) -> [TraceEvent] {
        var result: [TraceEvent] = []
        queue.sync {
            result = Array(self.events.suffix(limit))
        }
        return result
    }

    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            self?.events.removeAll()
        }
    }
}
