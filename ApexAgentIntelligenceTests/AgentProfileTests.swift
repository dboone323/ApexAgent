// AgentProfileTests.swift — ApexAgentIntelligenceTests
//
// Unit tests for agent profiles, model preferences, and session instantiation.
// Since these tests import and initialize FoundationModels and LanguageModelSession,
// they are placed in this target to avoid the CoreDevice framework conflict.

import Testing
import Foundation
import FoundationModels
import SwiftData
@testable import ApexAgentCore
import SharedModels
import AppKit

@Suite("Agent Profile Tests")
struct AgentProfileTests {

    @MainActor
    @Test func testModelProtocols() {
        let localModel: any LanguageModel = SystemLanguageModel.default
        let _ = localModel.capabilities
        #expect(Bool(true), "SystemLanguageModel is initialized successfully")
        
        if AgentOrchestrator.isPrivateCloudComputeAvailable() {
            let cloudModel = PrivateCloudComputeLanguageModel()
            let _ = cloudModel.capabilities
            #expect(Bool(true), "PrivateCloudComputeLanguageModel is initialized successfully")
        } else {
            print("⚠️ Private Cloud Compute entitlement not available; skipping PCC model test.")
        }
    }

    @MainActor
    @Test func testModelPreferenceConfiguration() {
        let orchestrator = AgentOrchestrator()
        #expect(orchestrator.modelPreference == .localSystem)
        
        if AgentOrchestrator.isPrivateCloudComputeAvailable() {
            orchestrator.modelPreference = .privateCloud
            orchestrator.resetSession()
            #expect(orchestrator.modelPreference == .privateCloud)
            #expect(orchestrator.session != nil)
        } else {
            print("⚠️ Private Cloud Compute entitlement not available; skipping privateCloud modelPreference test.")
        }
        
        orchestrator.modelPreference = .cloudGemini
        orchestrator.resetSession()
        #expect(orchestrator.modelPreference == .cloudGemini)
        #expect(orchestrator.session != nil)
    }

    @MainActor
    @Test func testDynamicProfile() {
        struct TestProfile: LanguageModelSession.DynamicProfile {
            var body: some LanguageModelSession.DynamicProfile {
                LanguageModelSession.Profile {
                    Instructions("Test Instructions")
                }
                .model(SystemLanguageModel.default)
                .toolCallingMode(.allowed)
            }
        }
        let transcript = Transcript(entries: [])
        let _ = LanguageModelSession(profile: TestProfile(), history: transcript)
        #expect(Bool(true), "LanguageModelSession initialized with dynamic profile successfully")
    }

    @MainActor
    @Test func testApexAgentProfileInstantiation() {
        let transcript = Transcript(entries: [])
        let orchestrator = AgentOrchestrator()
        let profile = ApexAgentProfile(
            instructions: "Test instructions",
            model: SystemLanguageModel.default,
            toolCallingMode: .allowed,
            orchestrator: orchestrator
        )
        let _ = LanguageModelSession(profile: profile, history: transcript)
        #expect(Bool(true), "LanguageModelSession initialized with ApexAgentProfile successfully")
    }

    @MainActor
    @Test func testNewAgentProfiles() {
        let transcript = Transcript(entries: [])
        let model = SystemLanguageModel.default
        let orchestrator = AgentOrchestrator()
        
        let linterProfile = LinterAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        let uiDesignerProfile = UIDesignerAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        let plannerProfile = PlannerAgentProfile(instructions: "Test", model: model, toolCallingMode: .allowed, orchestrator: orchestrator)
        
        let _ = LanguageModelSession(profile: linterProfile, history: transcript)
        let _ = LanguageModelSession(profile: uiDesignerProfile, history: transcript)
        let _ = LanguageModelSession(profile: plannerProfile, history: transcript)
        
        #expect(Bool(true), "LanguageModelSession initialized with new agent profiles successfully")
    }
}
