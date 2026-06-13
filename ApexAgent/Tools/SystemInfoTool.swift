import Foundation
import FoundationModels
import AppKit

// MARK: - System Info Tool

struct SystemInfoTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "get_system_info"
    let description = """
    Returns detailed information about the macOS system including \
    OS version, hardware model, chip, RAM, storage, and network info. \
    Use this to understand the environment before running system-specific commands.
    """

    @Generable
    struct Arguments: Decodable {}

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            var info = "## System Information\n\n"

            // OS Info
            let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
            info += "**OS:** macOS \(osVersion)\n"

            // Hardware info via sysctl
            func sysctlString(_ name: String) -> String {
                var size = 0
                sysctlbyname(name, nil, &size, nil, 0)
                var value = [CChar](repeating: 0, count: size)
                sysctlbyname(name, &value, &size, nil, 0)
                return String(cString: value)
            }

            func sysctlInt64(_ name: String) -> Int64 {
                var value: Int64 = 0
                var size = MemoryLayout<Int64>.size
                sysctlbyname(name, &value, &size, nil, 0)
                return value
            }

            let model = sysctlString("hw.model")
            let cpuBrand = sysctlString("machdep.cpu.brand_string")
            let physicalCPUs = sysctlInt64("hw.physicalcpu")
            let logicalCPUs = sysctlInt64("hw.logicalcpu")
            let memBytes = sysctlInt64("hw.memsize")
            let memGB = memBytes / 1_073_741_824

            info += "**Model:** \(model)\n"
            info += "**CPU:** \(cpuBrand)\n"
            info += "**Cores:** \(physicalCPUs) physical, \(logicalCPUs) logical\n"
            info += "**RAM:** \(memGB) GB unified memory\n"

            // Disk space
            let homeURL = URL(fileURLWithPath: NSHomeDirectory())
            if let values = try? homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                let total = (values.volumeTotalCapacity ?? 0) / 1_073_741_824
                let available = (values.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824
                info += "**Storage:** \(available) GB free of \(total) GB\n"
            }

            // Hostname and user
            info += "**Hostname:** \(ProcessInfo.processInfo.hostName)\n"
            info += "**Username:** \(NSUserName())\n"
            info += "**Home Directory:** \(NSHomeDirectory())\n"

            // Architecture
            #if arch(arm64)
            info += "**Architecture:** Apple Silicon (arm64)\n"
            #else
            info += "**Architecture:** Intel (x86_64)\n"
            #endif

            return info
        }
    }
}

// MARK: - Process List Tool

struct ProcessListTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }
    
    let name = "get_running_processes"
    let description = "Returns a list of currently running macOS applications (user-visible apps, not background daemons)."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "If true, includes background/hidden processes. If false (default), only shows user-visible apps.")
        var includeBackground: Bool?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            return await MainActor.run {
                let includeBackground = arguments.includeBackground ?? false

                let apps: [NSRunningApplication]
                if includeBackground {
                    apps = NSWorkspace.shared.runningApplications
                } else {
                    apps = NSWorkspace.shared.runningApplications.filter {
                        $0.activationPolicy == .regular
                    }
                }

                var output = "## Running Applications (\(apps.count))\n\n"
                for app in apps.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
                    let name = app.localizedName ?? "Unknown"
                    let pid = app.processIdentifier
                    let bundleID = app.bundleIdentifier ?? "unknown"
                    output += "• **\(name)** (PID: \(pid), Bundle: \(bundleID))\n"
                }

                return output
            }
        }
    }
}
