import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

@Suite("VoiceTTSProviderTests")
struct VoiceTTSProviderTests {
    @Test("Test TTSProvider.allCases contains .system and .elevenLabs")
    func testTTSProviderCases() {
        let cases = TTSProvider.allCases
        #expect(cases.contains(.system))
        #expect(cases.contains(.elevenLabs))
    }
    
    @Test("Test VoiceController.shared.selectedProvider defaults and switching")
    @MainActor
    func testVoiceControllerProvider() {
        let controller = VoiceController.shared
        
        controller.selectedProvider = .system
        #expect(controller.selectedProvider == .system)
        
        controller.selectedProvider = .elevenLabs
        #expect(controller.selectedProvider == .elevenLabs)
        controller.selectedProvider = .system
    }

    @Test("Test VoiceController stopSpeaking while ChatView is hosted does not trigger invalid observation updates")
    @MainActor
    func testVoiceControllerStopSpeakingDuringHostedChatView() {
        let orchestrator = AgentOrchestrator()
        let hosting = NSHostingView(rootView: ChatView().environment(orchestrator))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        hosting.layoutSubtreeIfNeeded()

        let controller = VoiceController.shared
        controller.stopSpeaking()
        #expect(controller.isSpeaking == false)
        #expect(controller.isRecording == false)

        orchestrator.cancelGeneration()
    }

    @Test("Test conversational greeting detection and isolated sub-agent session creation")
    @MainActor
    func testConversationalGreetingDetectionAndSubAgentSessionIsolation() {
        #expect(AgentOrchestrator.isConversationalGreetingOrSmallTalk("Hey"))
        #expect(AgentOrchestrator.isConversationalGreetingOrSmallTalk("Hello!"))
        #expect(AgentOrchestrator.isConversationalGreetingOrSmallTalk("Good morning"))
        #expect(!AgentOrchestrator.isConversationalGreetingOrSmallTalk("Audit the project files"))
        #expect(!AgentOrchestrator.isConversationalGreetingOrSmallTalk("Run ls -la in terminal"))

        let orchestrator = AgentOrchestrator()
        orchestrator.resetSession()
        let devAgent = AgentRegistry.shared.resolve(name: "developer")!
        let subSession1 = orchestrator.sessionForAgent(
            agent: devAgent,
            preference: orchestrator.modelPreference,
            instructions: devAgent.systemPrompt,
            allowedTools: ["read_file"],
            toolCallingMode: .allowed,
            prompt: "Inspect file"
        )
        let subSession2 = orchestrator.sessionForAgent(
            agent: devAgent,
            preference: orchestrator.modelPreference,
            instructions: devAgent.systemPrompt,
            allowedTools: ["read_file"],
            toolCallingMode: .allowed,
            prompt: "Inspect second file"
        )
        #expect(subSession1 !== subSession2)
        if let mainSession = orchestrator.session {
            #expect(subSession1 !== mainSession)
            #expect(subSession2 !== mainSession)
        }
    }

    @Test("TTSProvider badges and network requirement")
    func testTTSProviderBadgeAndNetwork() {
        #expect(TTSProvider.system.badge.contains("System"))
        #expect(!TTSProvider.system.requiresNetwork)
        #expect(TTSProvider.elevenLabs.requiresNetwork)
    }

    @Test("VoiceController state summary renders without touching the audio engine")
    @MainActor
    func testVoiceStateSummary() {
        let md = VoiceController.shared.stateSummaryMarkdown()
        #expect(md.contains("Voice Controller"))
        #expect(md.contains("Provider"))
    }
}
