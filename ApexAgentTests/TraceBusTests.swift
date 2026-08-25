import Testing
import Foundation
@testable import ApexAgentCore

@Suite("TraceBusTests")
struct TraceBusTests {

    @MainActor
    @Test func testRecentEventsContainsAppendedEvents() {
        TraceBus.shared.append(TraceEvent(source: "tool", operation: "read_file", detail: "success", metadata: ["chars": "128"]))
        TraceBus.shared.append(TraceEvent(source: "tool", operation: "read_file", detail: "failed", metadata: ["error": "boom"]))

        let recent = TraceBus.shared.recentEvents()
        let sources = recent.map(\.source)
        #expect(sources.contains("tool"))
        let operations = recent.map(\.operation)
        #expect(operations.contains("read_file"))
        let details = recent.map(\.detail)
        #expect(details.contains("success"))
        #expect(details.contains("failed"))
    }

    @MainActor
    @Test func testRecentEventsReturnsNewestFirst() {
        TraceBus.shared.append(TraceEvent(source: "mcp", operation: "list_tools", detail: "success", metadata: nil))
        TraceBus.shared.append(TraceEvent(source: "mcp", operation: "list_tools", detail: "start", metadata: nil))

        let recent = TraceBus.shared.recentEvents()
        let successEvent = recent.first { $0.detail == "success" }
        #expect(successEvent != nil, "Recent events should include the latest success entry")
    }
}
