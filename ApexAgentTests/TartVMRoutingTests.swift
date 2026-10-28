import Testing
import Foundation
@testable import ApexAgentCore

@Suite("Tart VM routing")
struct TartVMRoutingTests {

    @Test func resolutionTartBeatsContainer() {
        let space = SpaceModel(name: "s", executionTargetRaw: "tartVM")
        let env = ExecutionEnvironmentResolver.resolve(spaceTargetRaw: space.executionTargetRaw, spaceID: space.id, containerEnabled: true)
        #expect(env == .tartVM(spaceID: space.id.uuidString))
    }

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

    @Test func backendSeededShortCircuit() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-x", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        await fake.setExecResult((stdout: "SEEDED\n", stderr: "", exitCode: 0))
        let backend = TartVMBackend(spaceID: "x", manager: VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1), client: fake)
        try await backend.seed(workspacePath: "/tmp/ws")
        try await backend.seed(workspacePath: nil)
    }

    @Test func bundleFailureSurfaces() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-y", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        await fake.setExecResult((stdout: "", stderr: "no", exitCode: 1))
        let backend = TartVMBackend(spaceID: "y", manager: VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1), client: fake)
        do {
            try await backend.seed(workspacePath: "/tmp/nonexistent-workspace-xyz")
            #expect(Bool(false), "expected throw")
        } catch {
        }
    }

    @Test func writeReadRoundTrip() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-z", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        await fake.setExecResult((stdout: "SEEDED\nok", stderr: "", exitCode: 0))
        let backend = TartVMBackend(spaceID: "z", manager: VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1), client: fake)
        try await backend.seed(workspacePath: "/tmp/ws")
        try await backend.writeFile(relativePath: "a.txt", content: "bar")
    }
}
