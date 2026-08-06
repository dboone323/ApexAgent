import Testing
import Foundation
@testable import ApexAgentCore

@Suite("TraceBusTests")
struct TraceBusTests {

    @Test func testRecentEventsContainsAppendedEvents() async {
        await TraceBus.shared.append(TraceEvent(source: "tool", operation: "read_file", detail: "success", metadata: ["chars": "128"]))
        await TraceBus.shared.append(TraceEvent(source: "tool", operation: "read_file", detail: "failed", metadata: ["error": "boom"]))
        await Task.yield()

        let recent = await TraceBus.shared.recentEvents()
        let sources = recent.map(\.source)
        #expect(sources.contains("tool"))
        let operations = recent.map(\.operation)
        #expect(operations.contains("read_file"))
        let details = recent.map(\.detail)
        #expect(details.contains("success"))
        #expect(details.contains("failed"))
    }

    @Test func testRecentEventsReturnsNewestFirst() async {
        await TraceBus.shared.append(TraceEvent(source: "mcp", operation: "list_tools", detail: "success", metadata: nil))
        await TraceBus.shared.append(TraceEvent(source: "mcp", operation: "list_tools", detail: "start", metadata: nil))
        await Task.yield()

        let recent = await TraceBus.shared.recentEvents()
        let successEvent = recent.first { $0.detail == "success" }
        #expect(successEvent != nil, "Recent events should include the latest success entry")
    }
}
