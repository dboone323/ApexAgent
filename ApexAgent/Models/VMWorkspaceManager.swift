import Foundation

public actor VMWorkspaceManager {
    public static let vmNamePrefix = "apex-space-"
    public static func vmName(for spaceID: String) -> String {
        "\(vmNamePrefix)\(spaceID)"
    }
    public static let sourceVMName = "apex-base"
    public static let defaultCPU = 8
    public static let defaultMemoryMB = 10240
    public static let maxConcurrentRunning = 2

    public enum Status: Sendable, Equatable {
        case notProvisioned
        case stopped
        case starting
        case ready
        case error(String)
    }

    public enum ManagerError: Error, Sendable, Equatable {
        case tooManyRunning(current: Int, limit: Int)
    }

    private let client: any TartClientProtocol
    private let sourceName: String
    private let cpu: Int
    private let memoryMB: Int
    private let readyTimeoutSeconds: TimeInterval

    private var statuses: [String: Status] = [:]
    private var runningSpaces: Set<String> = []

    private var buildLockHeld: Bool = false
    private var buildWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        client: any TartClientProtocol = TartCLIClient(),
        sourceName: String = VMWorkspaceManager.sourceVMName,
        cpu: Int = VMWorkspaceManager.defaultCPU,
        memoryMB: Int = VMWorkspaceManager.defaultMemoryMB,
        readyTimeoutSeconds: TimeInterval = 120
    ) {
        self.client = client
        self.sourceName = sourceName
        self.cpu = cpu
        self.memoryMB = memoryMB
        self.readyTimeoutSeconds = readyTimeoutSeconds
    }

    public func status(for spaceID: String) -> Status {
        statuses[spaceID, default: .notProvisioned]
    }

    public var runningCount: Int { runningSpaces.count }

    public func ensureProvisioned(spaceID: String) async throws {
        let name = Self.vmName(for: spaceID)
        do {
            let vms = try await client.list()
            if !vms.contains(where: { $0.name == name }) {
                try await client.clone(source: sourceName, name: name)
            }
            try await client.set(name: name, cpu: cpu, memoryMB: memoryMB)
            if statuses[spaceID] == nil || statuses[spaceID] == .notProvisioned {
                statuses[spaceID] = .stopped
            }
        } catch {
            statuses[spaceID] = .error(String(describing: error))
            throw error
        }
    }

    public func startIfNeeded(spaceID: String) async throws {
        if runningSpaces.contains(spaceID) {
            if status(for: spaceID) == .ready { return }
        } else if runningSpaces.count >= Self.maxConcurrentRunning {
            let err = ManagerError.tooManyRunning(current: runningSpaces.count, limit: Self.maxConcurrentRunning)
            statuses[spaceID] = .error(String(describing: err))
            throw err
        }

        let name = Self.vmName(for: spaceID)
        statuses[spaceID] = .starting
        do {
            try? await client.run(name: name, softnet: true)
            let deadline = Date().addingTimeInterval(readyTimeoutSeconds)
            while Date() < deadline {
                do {
                    let result = try await client.exec(name: name, arguments: ["echo", "ok"])
                    if result.exitCode == 0 && result.stdout.contains("ok") {
                        statuses[spaceID] = .ready
                        runningSpaces.insert(spaceID)
                        return
                    }
                } catch {
                    // VM not ready yet.
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
            statuses[spaceID] = .error("VM did not become ready within \(Int(readyTimeoutSeconds))s")
            throw TartCLIClientError.timeout
        } catch let error as TartCLIClientError {
            statuses[spaceID] = .error(String(describing: error))
            throw error
        } catch {
            statuses[spaceID] = .error(String(describing: error))
            throw error
        }
    }

    public func stop(spaceID: String) async throws {
        let name = Self.vmName(for: spaceID)
        try await client.stop(name: name)
        runningSpaces.remove(spaceID)
        statuses[spaceID] = .stopped
    }

    public func destroy(spaceID: String) async throws {
        let name = Self.vmName(for: spaceID)
        try await client.delete(name: name)
        runningSpaces.remove(spaceID)
        statuses.removeValue(forKey: spaceID)
    }

    // MARK: Build lock

    private func acquireBuildLock() async {
        if !buildLockHeld {
            buildLockHeld = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            buildWaiters.append(cont)
        }
    }

    private func releaseBuildLock() {
        if let next = buildWaiters.first {
            buildWaiters.removeFirst()
            next.resume()
        } else {
            buildLockHeld = false
        }
    }

    public func withBuildLock<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquireBuildLock()
        defer { releaseBuildLock() }
        return try await operation()
    }
}
