import Testing
import Foundation
import AppKit
@testable import ApexAgentCore

@Suite("WritingToolsSupportTests") final class WritingToolsSupportTests {
    

    @MainActor
    @Test func testWritingToolsSupportRegister() {
        WritingToolsSupport.register()
        if #available(macOS 15.0, *) {
            #expect(NSApp.servicesProvider != nil)
        }
    }

    
    @MainActor
    @Test func testAPEXWritingToolsIntegrationEmptyText() {
        let orchestrator = AgentOrchestrator()
        let result = APEXWritingToolsIntegration.shared.processText("", using: orchestrator)
        #expect(!(result))
    }
    
    @MainActor
    @Test func testAPEXWritingToolsIntegrationSuccess() async {
        let orchestrator = AgentOrchestrator()
        let result = APEXWritingToolsIntegration.shared.processText("Improve this text.", using: orchestrator)
        #expect(result)
        
        // Wait a small amount of time for the async Task to execute
        try? await Task.sleep(for: .milliseconds(50))
    }
    
    @MainActor
    @Test func testHandleWritingToolsRequestSuccess() async {
        let support = WritingToolsSupport.shared
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.writeObjects(["Original Text to Refine" as NSString])
        
        var errorString: NSString?
        support.handleWritingToolsRequest(pasteboard, userData: "", error: &errorString)
        
        #expect(errorString == nil)
        
        // Wait a small amount of time for the async Task to execute
        try? await Task.sleep(for: .milliseconds(50))
    }
    
    @MainActor
    @Test func testHandleWritingToolsRequestFailure() async {
        let support = WritingToolsSupport.shared
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        
        var errorString: NSString?
        
        pasteboard.writeObjects(["" as NSString])
        support.handleWritingToolsRequest(pasteboard, userData: "", error: &errorString)
        #expect(errorString as String? == "Failed to process Writing Tools request")
    }
}
