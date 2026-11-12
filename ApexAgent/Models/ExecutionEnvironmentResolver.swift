import Foundation

public enum ExecutionEnvironmentResolver {

    public struct SpaceSnapshot: Sendable, Equatable {
        public let id: UUID
        public let isSeatbelt: Bool
        public let workspacePath: String

        public init(id: UUID, isSeatbelt: Bool, workspacePath: String) {
            self.id = id
            self.isSeatbelt = isSeatbelt
            self.workspacePath = workspacePath
        }

        public init(space: SpaceModel) {
            self.id = space.id
            self.isSeatbelt = space.isSeatbelt
            self.workspacePath = space.workspacePath
        }
    }

    public static func resolve(spaceTargetRaw: String?, spaceID: UUID?, containerEnabled: Bool) -> ExecutionEnvironment {
        if spaceTargetRaw == "seatbelt" {
            return .seatbelt(spaceID: spaceID?.uuidString ?? "")
        }
        if containerEnabled { return .appleContainer }
        return .host
    }

    public static func resolve(space: SpaceSnapshot?, containerEnabled: Bool) -> ExecutionEnvironment {
        guard let space else {
            return containerEnabled ? .appleContainer : .host
        }
        if space.isSeatbelt {
            return .seatbelt(spaceID: space.id.uuidString)
        }
        return containerEnabled ? .appleContainer : .host
    }

    public static func resolveCurrent(orchestrator: AgentOrchestrator) async -> (ExecutionEnvironment, String?) {
        let containerEnabled = UserDefaults.standard.bool(forKey: "apex.appleContainersEnabled")
        let wsPath = await MainActor.run { orchestrator.currentWorkspacePath }
        let space: SpaceSnapshot? = await MainActor.run {
            if let id = SpaceManager.shared.activeSpaceId,
               let sp = SpaceManager.shared.spaces.first(where: { $0.id == id }) {
                return SpaceSnapshot(space: sp)
            }
            if let sp = SpaceManager.shared.spaces.first(where: { $0.workspacePath == wsPath }) {
                return SpaceSnapshot(space: sp)
            }
            return nil
        }
        let env = resolve(space: space, containerEnabled: containerEnabled)
        let workspacePath: String? = space?.workspacePath ?? (isSeatbelt(env) ? wsPath : nil)
        return (env, workspacePath)
    }

    public static func isSeatbelt(_ env: ExecutionEnvironment) -> Bool {
        if case .seatbelt = env { return true }
        return false
    }

    public static func mapPath(_ rawPath: String, workspacePath: String) throws -> String {
        try mapToGuest(rawPath, workspacePath: workspacePath)
    }

    public static func mapToGuest(_ rawPath: String, workspacePath: String) throws -> String {
        let clean = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: clean).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            return expanded.isEmpty ? "." : expanded
        }
        let ws = workspacePath.isEmpty ? "/" : workspacePath
        let standardizedWs = URL(fileURLWithPath: ws).standardized.path
        let standardizedPath = URL(fileURLWithPath: expanded).standardized.path
        if standardizedPath == standardizedWs {
            return "."
        }
        let prefix = standardizedWs.hasSuffix("/") ? standardizedWs : standardizedWs + "/"
        if standardizedPath.hasPrefix(prefix) {
            return String(standardizedPath.dropFirst(prefix.count))
        }
        throw NSError(domain: "ExecutionEnvironmentResolver", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "ERROR: path outside workspace: \(expanded)"])
    }
}

public func mapPathToGuest(_ rawPath: String, workspacePath: String) throws -> String {
    try ExecutionEnvironmentResolver.mapPath(rawPath, workspacePath: workspacePath)
}

public func mapToGuestPath(_ rawPath: String, workspacePath: String) throws -> String {
    try ExecutionEnvironmentResolver.mapPath(rawPath, workspacePath: workspacePath)
}

public actor SeatbeltBackendRegistry {
    public static let shared = SeatbeltBackendRegistry()
    private var backends: [String: SeatbeltBackend] = [:]
    public func backend(for spaceID: String, workspacePath: String = "", allowNetwork: Bool = true) -> SeatbeltBackend {
        if let b = backends[spaceID] { return b }
        let b = SeatbeltBackend(spaceID: spaceID, workspacePath: workspacePath, allowNetwork: allowNetwork)
        backends[spaceID] = b
        return b
    }
}
