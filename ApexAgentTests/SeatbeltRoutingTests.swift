import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Seatbelt routing unit tests")
struct SeatbeltRoutingTests {

    @Test func resolutionSeatbeltBeatsContainer() {
        let space = SpaceModel(name: "seatbelt-space", executionTargetRaw: "seatbelt")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: true)
        #expect(env == .seatbelt(spaceID: space.id.uuidString))
    }

    @Test func resolutionTartBeatsSeatbelt() {
        let space = SpaceModel(name: "vm-space", executionTargetRaw: "tartVM")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: true)
        #expect(env == .tartVM(spaceID: space.id.uuidString))
    }

    @Test func resolutionSeatbeltPrecedenceOverHost() {
        let space = SpaceModel(name: "seatbelt-space", executionTargetRaw: "seatbelt")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: false)
        #expect(env == .seatbelt(spaceID: space.id.uuidString))
    }

    @Test func resolutionFromSpaceModel() {
        let space = SpaceModel(name: "seatbelt-space", executionTargetRaw: "seatbelt")
        #expect(space.isSeatbelt == true)
        #expect(space.isSandboxVM == false)
        let env = ExecutionEnvironmentResolver.resolve(space: space, containerEnabled: true)
        #expect(env == .seatbelt(spaceID: space.id.uuidString))
    }

    @Test func profileGenerationRulesNetworkAllowed() {
        let ws = "/tmp/test-seatbelt-ws"
        let profile = SeatbeltProfile(workspacePath: ws, allowNetwork: true)
        let generated = profile.generate()

        #expect(generated.contains("(version 1)"))
        #expect(generated.contains("(allow default)"))
        #expect(generated.contains("(deny file-write*)"))
        #expect(generated.contains("(allow file-write*"))
        #expect(generated.contains(profile.tempDirectory) || generated.contains(".apex/tmp"))
        #expect(generated.contains(profile.derivedDataDirectory) || generated.contains(".apex/DerivedData"))
        #expect(!generated.contains("(deny network*)"))
    }

    @Test func profileGenerationRulesNetworkDenied() {
        let ws = "/tmp/test-seatbelt-ws"
        let profile = SeatbeltProfile(workspacePath: ws, allowNetwork: false)
        let generated = profile.generate()

        #expect(generated.contains("(version 1)"))
        #expect(generated.contains("(allow default)"))
        #expect(generated.contains("(deny file-write*)"))
        #expect(generated.contains("(allow file-write*"))
        #expect(generated.contains("(deny network*)"))

        // Seatbelt is last-matching-rule-wins: (deny network*) must come after (allow default)
        let allowRange = generated.range(of: "(allow default)")
        let denyNetRange = generated.range(of: "(deny network*)")
        #expect(allowRange != nil && denyNetRange != nil)
        if let ar = allowRange, let dr = denyNetRange {
            #expect(dr.lowerBound > ar.upperBound)
        }
    }

    @Test func profileDeterministicOutput() {
        let ws = "/tmp/test-deterministic"
        let p1 = SeatbeltProfile(workspacePath: ws, allowNetwork: true).generate()
        let p2 = SeatbeltProfile(workspacePath: ws, allowNetwork: true).generate()
        #expect(p1 == p2)
    }
}
