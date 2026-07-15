import Foundation
import FoundationModels

struct ContainerStatusTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "manage_sandbox"
    let description = "Queries status and manages the native macOS Apple Container sandbox (start, stop, check status)."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The action to perform: 'status' (get details), 'start' (boot sandbox micro-VM), 'stop' (shut down micro-VM). Defaults to 'status'.")
        var action: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let action = arguments.action ?? "status"
            guard let manager = await ContainerBridge.shared else {
                return "ERROR: Sandbox is not supported in this target."
            }
            switch action.lowercased() {
            case "start":
                do {
                    try await manager.startContainer()
                    return "SUCCESS: Apple Container sandbox started successfully. Status: Running."
                } catch {
                    return "ERROR: Failed to start sandbox container: \(error.localizedDescription)"
                }
            case "stop":
                do {
                    try await manager.stopContainer()
                    return "SUCCESS: Apple Container sandbox stopped successfully. Status: Stopped."
                } catch {
                    return "ERROR: Failed to stop sandbox container: \(error.localizedDescription)"
                }
            case "status":
                let stateDesc = await manager.stateDescription
                let cpus = await manager.containerCPUs
                let memory = await manager.containerMemoryMB
                let image = await manager.appleContainerImage
                return """
                Sandbox Configuration:
                - State: \(stateDesc)
                - Allocated CPUs: \(cpus)
                - Allocated Memory: \(memory) MB
                - Container Image: \(image)
                """
            default:
                return "ERROR: Unknown action '\(action)'. Valid actions are 'status', 'start', 'stop'."
            }
        }
    }
}
