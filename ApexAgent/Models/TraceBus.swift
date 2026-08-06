import Foundation
import Observation

@Observable
final class TraceBus: @unchecked Sendable {
    static let shared = TraceBus()

    private(set) var events: [TraceEvent] = []
    private let maxEvents: Int = 400
    private let queue = DispatchQueue(label: "com.apexagent.tracebus", attributes: .concurrent)

    private init() {}

    func append(_ event: TraceEvent) {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            if self.events.count >= self.maxEvents {
                self.events.removeFirst(self.events.count - self.maxEvents + 1)
            }
            self.events.append(event)
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
