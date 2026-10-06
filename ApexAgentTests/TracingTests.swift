import Testing
import Foundation
@testable import ApexAgentCore

@MainActor
@Suite("TracingTests")
struct TracingTests {

    @Test func spanRecordsToTraceBusWithDuration() async throws {
        // Clear any prior spans so the assertion is deterministic.
        TraceBus.shared.clear()

        let result = await Tracing.span("test.operation", source: "TracingTests") {
            try? await Task.sleep(for: .milliseconds(20))
            return 42
        }
        #expect(result == 42)

        let events = Tracing.recentTraces(limit: 10)
        #expect(!events.isEmpty, "Tracing.span should append a TraceEvent to the bus")
        let span = events.last!
        #expect(span.source == "TracingTests")
        #expect(span.operation == "test.operation")
        #expect(span.durationMs != nil && span.durationMs! >= 10, "Duration should reflect the ~20ms sleep")
    }

    @Test func eventRecordsSinglePointTrace() async throws {
        TraceBus.shared.clear()
        Tracing.event("test.event", source: "TracingTests", detail: "hello")
        let events = Tracing.recentTraces(limit: 10)
        #expect(events.contains { $0.operation == "test.event" && $0.source == "TracingTests" })
    }
}

// MARK: - Trace event reporting

@Suite("TraceEventReportingTests")
struct TraceEventReportingTests {
    @Test func traceEvent() {
        let e = TraceEvent(source: "orchestrator", operation: "tool_call", detail: "ls", durationMs: 50)
        #expect(e.isWellFormed)
        #expect(!e.isSlow)
        #expect(e.formatAsMarkdown().contains("tool_call"))
        let slow = TraceEvent(source: "s", operation: "o", durationMs: 5000)
        #expect(slow.isSlow)
        let bad = TraceEvent(source: "", operation: "")
        #expect(!bad.isWellFormed)
    }
}
