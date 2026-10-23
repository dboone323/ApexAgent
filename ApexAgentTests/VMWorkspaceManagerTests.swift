import Testing
import Foundation
@testable import ApexAgentCore

actor OrderCollector {
    private var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
    func snapshot() -> [Int] { values }
}

actor FakeTartClient: TartClientProtocol {
    var vms: [TartVMInfo] = []
    private(set) var cloneCalled = false
    private(set) var setCalled = false
    private(set) var runCalled = false
    private(set) var stopCalled = false
    private(set) var deleteCalled = false
    var execResult: (stdout: String, stderr: String, exitCode: Int32) = ("ok\n", "", 0)

    func setVMs(_ vms: [TartVMInfo]) { self.vms = vms }

    func clone(source: String, name: String) async throws {
        cloneCalled = true
        vms.append(TartVMInfo(name: name, source: "local", state: "stopped", running: false, diskSize: 10, size: 10))
    }
    func set(name: String, cpu: Int?, memoryMB: Int?) async throws {
        setCalled = true
    }
    func run(name: String, softnet: Bool) async throws {
        runCalled = true
    }
    func exec(name: String, arguments: [String]) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
        execResult
    }
    func ip(name: String, wait: Int?) async throws -> String {
        "192.168.2.20"
    }
    func stop(name: String) async throws {
        stopCalled = true
    }
    func delete(name: String) async throws {
        deleteCalled = true
        vms.removeAll { $0.name == name }
    }
    func list() async throws -> [TartVMInfo] {
        vms
    }
}

@Suite("VMWorkspaceManager state transitions")
struct VMWorkspaceManagerTests {
    @Test func ensureProvisionedClonesWhenMissing() async throws {
        let fake = FakeTartClient()
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        try await mgr.ensureProvisioned(spaceID: "alpha")
        #expect(await fake.cloneCalled)
        #expect(await fake.setCalled)
        #expect(await mgr.status(for: "alpha") == .stopped)
        #expect(await fake.vms.contains(where: { $0.name == "apex-space-alpha" }))
    }

    @Test func ensureProvisionedSkipsCloneWhenPresent() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-alpha", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        try await mgr.ensureProvisioned(spaceID: "alpha")
        #expect(!(await fake.cloneCalled))
        #expect(await fake.setCalled)
    }

    @Test func startIfNeededBecomesReady() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-alpha", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 5)
        try await mgr.ensureProvisioned(spaceID: "alpha")
        try await mgr.startIfNeeded(spaceID: "alpha")
        #expect(await fake.runCalled)
        #expect(await mgr.status(for: "alpha") == .ready)
        #expect(await mgr.runningCount == 1)
    }

    @Test func stopAndDestroy() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([TartVMInfo(name: "apex-space-alpha", source: "local", state: "stopped", running: false, diskSize: 10, size: 10)])
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        try await mgr.ensureProvisioned(spaceID: "alpha")
        try await mgr.stop(spaceID: "alpha")
        #expect(await fake.stopCalled)
        #expect(await mgr.status(for: "alpha") == .stopped)
        try await mgr.destroy(spaceID: "alpha")
        #expect(await fake.deleteCalled)
        #expect(await mgr.status(for: "alpha") == .notProvisioned)
    }

    @Test func concurrencyLimitEnforced() async throws {
        let fake = FakeTartClient()
        await fake.setVMs([
            TartVMInfo(name: "apex-space-a", source: "local", state: "stopped", running: false, diskSize: 10, size: 10),
            TartVMInfo(name: "apex-space-b", source: "local", state: "stopped", running: false, diskSize: 10, size: 10),
            TartVMInfo(name: "apex-space-c", source: "local", state: "stopped", running: false, diskSize: 10, size: 10),
        ])
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 5)
        try await mgr.ensureProvisioned(spaceID: "a")
        try await mgr.ensureProvisioned(spaceID: "b")
        try await mgr.ensureProvisioned(spaceID: "c")
        try await mgr.startIfNeeded(spaceID: "a")
        try await mgr.startIfNeeded(spaceID: "b")
        #expect(await mgr.runningCount == 2)
        do {
            try await mgr.startIfNeeded(spaceID: "c")
            #expect(Bool(false), "expected tooManyRunning")
        } catch {
            #expect(error is VMWorkspaceManager.ManagerError)
        }
    }

    @Test func buildLockSerializes() async throws {
        let fake = FakeTartClient()
        let mgr = VMWorkspaceManager(client: fake, readyTimeoutSeconds: 1)
        let collector = OrderCollector()
        async let a: Void = mgr.withBuildLock {
            await collector.append(1)
            try await Task.sleep(nanoseconds: 100_000_000)
            await collector.append(2)
        }
        async let b: Void = mgr.withBuildLock {
            await collector.append(3)
            await collector.append(4)
        }
        _ = try await (a, b)
        let order = await collector.snapshot()
        #expect(order == [1, 2, 3, 4])
    }
}
