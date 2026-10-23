import Foundation

public enum ExecutionEnvironmentResolver {

    public static func resolve(spaceTargetRaw: String?, spaceID: UUID?, containerEnabled: Bool) -> ExecutionEnvironment {
        if spaceTargetRaw == "tartVM", let id = spaceID {
            return .tartVM(spaceID: id.uuidString)
        }
        if containerEnabled { return .appleContainer }
        return .host
    }

    public static func resolve(space: SpaceModel?, containerEnabled: Bool) -> ExecutionEnvironment {
        guard let space else {
            return containerEnabled ? .appleContainer : .host
        }
        if space.isSandboxVM {
            return .tartVM(spaceID: space.id.uuidString)
        }
        return containerEnabled ? .appleContainer : .host
    }

    public static func resolveCurrent(orchestrator: AgentOrchestrator) async -> (ExecutionEnvironment, String?) {
        let containerEnabled = UserDefaults.standard.bool(forKey: "apex.appleContainersEnabled")
        let wsPath = await MainActor.run { orchestrator.currentWorkspacePath }
        let space: SpaceModel? = await MainActor.run {
            if let id = SpaceManager.shared.activeSpaceId,
               let sp = SpaceManager.shared.spaces.first(where: { $0.id == id }) {
                return sp
            }
            return SpaceManager.shared.spaces.first(where: { $0.workspacePath == wsPath })
        }
        let env = resolve(space: space, containerEnabled: containerEnabled)
        let workspacePath: String? = space?.workspacePath ?? (isTart(env) ? wsPath : nil)
        return (env, workspacePath)
    }

    public static func isTart(_ env: ExecutionEnvironment) -> Bool {
        if case .tartVM = env { return true }
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

public actor TartVMBackendRegistry {
    public static let shared = TartVMBackendRegistry()
    private var backends: [String: TartVMBackend] = [:]
    public func backend(for spaceID: String) -> TartVMBackend {
        if let b = backends[spaceID] { return b }
        let b = TartVMBackend(spaceID: spaceID)
        backends[spaceID] = b
        return b
    }
}
