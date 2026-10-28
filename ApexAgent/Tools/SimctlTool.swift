import Foundation
import FoundationModels

struct SimctlTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "simctl"
    let description = "iOS Simulator control via xcrun simctl."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action: 'list', 'boot', 'shutdown', 'install', 'launch', 'screenshot', 'openurl'")
        var action: String
        
        @Guide(description: "Simulator device ID")
        var deviceId: String?
        
        @Guide(description: "Path to app to install")
        var appPath: String?
        
        @Guide(description: "Bundle ID of app to launch")
        var bundleId: String?
        
        @Guide(description: "URL to open")
        var url: String?
        
        @Guide(description: "Path to save screenshot")
        var savePath: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let riskDesc: String?
        if ["boot", "install", "launch"].contains(arguments.action) {
            riskDesc = "Controlling iOS Simulator"
        } else {
            riskDesc = nil
        }
        
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: riskDesc) {
            var simEnv = ProcessInfo.processInfo.environment
            if simEnv["DEVELOPER_DIR"] == nil,
               FileManager.default.fileExists(atPath: "/Applications/Xcode-beta.app/Contents/Developer") {
                simEnv["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.environment = simEnv
            
            var args = ["simctl", arguments.action]
            
            switch arguments.action {
            case "list":
                args.append(contentsOf: ["devices", "-j"])
            case "boot":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for boot" }
                // Checking booted devices
                let listProcess = Process()
                listProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                listProcess.environment = simEnv
                listProcess.arguments = ["simctl", "list", "devices", "-j"]
                let listPipe = Pipe()
                listProcess.standardOutput = listPipe

                let listTimeoutTask = Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    if listProcess.isRunning {
                        listProcess.terminate()
                    }
                }
                defer { listTimeoutTask.cancel() }

                try listProcess.run()
                let listData = try listPipe.fileHandleForReading.readToEnd() ?? Data()
                listProcess.waitUntilExit()
                
                var bootedCount = 0
                if let json = try? JSONSerialization.jsonObject(with: listData) as? [String: Any],
                   let devices = json["devices"] as? [String: [[String: Any]]] {
                    for (_, deviceList) in devices {
                        for dev in deviceList {
                            if let state = dev["state"] as? String, state == "Booted" {
                                bootedCount += 1
                            }
                        }
                    }
                }
                
                if bootedCount >= 2 {
                    return "ERROR: 2 or more devices are already booted. Please shutdown a device first."
                }
                args.append(deviceId)
            case "shutdown":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for shutdown" }
                args.append(deviceId)
            case "install":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for install" }
                guard let appPath = arguments.appPath else { return "ERROR: appPath required for install" }
                if !FileManager.default.fileExists(atPath: appPath) {
                    return "ERROR: App path does not exist: \(appPath)"
                }
                args.append(contentsOf: [deviceId, appPath])
            case "launch":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for launch" }
                guard let bundleId = arguments.bundleId else { return "ERROR: bundleId required for launch" }
                args.append(contentsOf: [deviceId, bundleId])
            case "screenshot":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for screenshot" }
                guard let savePath = arguments.savePath else { return "ERROR: savePath required for screenshot" }
                args.insert("io", at: 1)
                args.append(contentsOf: [deviceId, "screenshot", savePath])
            case "openurl":
                guard let deviceId = arguments.deviceId else { return "ERROR: deviceId required for openurl" }
                guard let url = arguments.url else { return "ERROR: url required for openurl" }
                args.append(contentsOf: [deviceId, url])
            default:
                return "ERROR: Invalid action '\(arguments.action)'"
            }
            
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    var output = String(decoding: data, as: UTF8.self)
                    
                    if arguments.action == "list" {
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let devices = json["devices"] as? [String: [[String: Any]]] {
                            var lines = ["Name | UDID | State"]
                            lines.append("-------------------------")
                            for (_, deviceList) in devices {
                                for dev in deviceList {
                                    if let name = dev["name"] as? String,
                                       let udid = dev["udid"] as? String,
                                       let state = dev["state"] as? String {
                                        lines.append("\(name) | \(udid) | \(state)")
                                    }
                                }
                            }
                            output = lines.joined(separator: "\n")
                        }
                    }
                    
                    if process.terminationStatus != 0 {
                        return "ERROR: Command failed with status \(process.terminationStatus).\nOutput: \(output)"
                    }
                    
                    return output.isEmpty ? "Success" : output
                }
                
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    process.terminate()
                    throw NSError(domain: "SimctlTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "Command timed out after 30 seconds."])
                }
                
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        }
    }
}
