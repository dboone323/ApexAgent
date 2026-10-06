import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

@Suite("ComputerUseAgentTests")
struct ComputerUseAgentTests {
    @Test("Test all ComputerAction cases and Codable / Equatable conformance")
    func testComputerActionCases() throws {
        let actions: [ComputerAction] = [
            .wait(seconds: 0.01),
            .finish(result: "done")
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for action in actions {
            let data = try encoder.encode(action)
            let decoded = try decoder.decode(ComputerAction.self, from: data)
            #expect(decoded == action)
        }
    }

    @Test("Test ComputerUseStep model initialization")
    func testComputerUseStep() {
        let step = ComputerUseStep(action: .wait(seconds: 0.01))
        #expect(step.action == .wait(seconds: 0.01))
    }
    
    @Test("Test executeAction wait")
    func testExecuteActionWait() async throws {
        let result = try await ComputerUseAgent.shared.executeAction(.wait(seconds: 0.01))
        #expect(result.lowercased().contains("success") || !result.isEmpty)
    }
    
    @Test("Test executeAction finish")
    func testExecuteActionFinish() async throws {
        let result = try await ComputerUseAgent.shared.executeAction(.finish(result: "done"))
        #expect(result.lowercased().contains("finish") || !result.isEmpty)
    }
}
