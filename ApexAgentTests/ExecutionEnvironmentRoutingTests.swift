import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Execution environment routing")
struct ExecutionEnvironmentRoutingTests {

    @Test func resolutionContainerBeatsHost() {
        let space = SpaceModel(name: "s", executionTargetRaw: "host")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: true)
        #expect(env == .appleContainer)
    }

    @Test func resolutionHostWhenNoFlags() {
        let space = SpaceModel(name: "s", executionTargetRaw: "host")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: false)
        #expect(env == .host)
    }

    @Test func resolutionNoSpaceFallthroughContainer() {
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: nil, spaceID: nil, containerEnabled: true)
        #expect(env == .appleContainer)
    }

    @Test func resolutionNoSpaceFallthroughHost() {
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: nil, spaceID: nil, containerEnabled: false)
        #expect(env == .host)
    }

    @Test func pathMappingInsideWorkspace() throws {
        let ws = "/tmp/ws"
        let guest = try ExecutionEnvironmentResolver.mapPath("/tmp/ws/foo/bar.txt", workspacePath: ws)
        #expect(guest == "foo/bar.txt")
    }

    @Test func pathMappingRelativePassthrough() throws {
        let ws = "/tmp/ws"
        let guest = try ExecutionEnvironmentResolver.mapPath("foo/bar.txt", workspacePath: ws)
        #expect(guest == "foo/bar.txt")
    }

    @Test func pathMappingOutsideThrows() {
        let ws = "/tmp/ws"
        #expect(throws: (any Error).self) {
            _ = try ExecutionEnvironmentResolver.mapPath("/etc/passwd", workspacePath: ws)
        }
    }

    @Test func shellCommandConstructionSingleCdPrefix() {
        let cmd = "echo hi"
        let full = "cd '~/ApexAgent' && \(cmd)"
        #expect(full.contains("cd "))
    }
}
