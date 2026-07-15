import Testing
import Foundation
@testable import ApexAgentCore

// Conformer for testing the extension
private final class TestToolRouter: DynamicToolRouting {}

@Suite("DynamicToolRoutingTests") final class DynamicToolRoutingTests {
    @Test func testPlaceholder() {
        // testClassifyAndRouteToolCalls has been moved to ApexAgentIntelligenceTests/AgentIntelligenceTests.swift
        // as it requires FoundationModels and was prone to UniversalHID segfaults.
        #expect(true)
    }
}
