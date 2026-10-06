import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

@Suite("TraceBusEventStreamTests")
struct TraceBusEventStreamTests {
    @Test("Test TraceBus.shared.eventStream()")
    func testTraceBusEventStream() async throws {
        let bus = TraceBus.shared
        let uniqueID = UUID().uuidString
        
        let task = Task {
            for await event in bus.eventStream() {
                if event.detail == uniqueID {
                    return true
                }
            }
            return false
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        bus.append(TraceEvent(source: "test", operation: "log", detail: uniqueID))
        
        let found = await task.value
        #expect(found)
    }
    
    @Test("Test TraceBus.shared.stream(forCategory:)")
    func testTraceBusStreamForCategory() async throws {
        let bus = TraceBus.shared
        let uniqueID = UUID().uuidString
        let category = "targetCategory"
        
        let task = Task {
            for await event in bus.stream(forCategory: category) {
                if event.detail == uniqueID {
                    return true
                }
            }
            return false
        }
        
        try await Task.sleep(nanoseconds: 50_000_000)
        bus.append(TraceEvent(source: "otherCategory", operation: "log", detail: "ignore"))
        bus.append(TraceEvent(source: category, operation: "log", detail: uniqueID))
        
        let found = await task.value
        #expect(found)
    }
}
