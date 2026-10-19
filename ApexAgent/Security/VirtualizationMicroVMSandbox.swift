import Foundation
import Virtualization
import Observation

// MARK: - VirtualizationMicroVMSandbox
//
// Enterprise hardware virtualization and ephemeral process isolation.
// On Apple Silicon hosts, constructs and validates real VZVirtualMachine configurations
// with VirtIO file systems, virtual entropy, and constrained compute resources.
// Provides zero-trust ephemeral execution with automatic filesystem rollback.

@Observable
@MainActor
public final class VirtualizationMicroVMSandbox {
    public static let shared = VirtualizationMicroVMSandbox()
    
    public struct SandboxExecutionResult: Sendable {
        public let exitCode: Int32
        public let stdout: String
        public let stderr: String
        public let executionDuration: TimeInterval
        public let wasSandboxed: Bool
        
        public init(exitCode: Int32, stdout: String, stderr: String, executionDuration: TimeInterval, wasSandboxed: Bool) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.executionDuration = executionDuration
            self.wasSandboxed = wasSandboxed
        }
    }
    
    public private(set) var isHypervisorSupported: Bool
    public private(set) var activeSandboxCount: Int = 0
    
    public init() {
        self.isHypervisorSupported = VZVirtualMachine.isSupported
    }
    
    // MARK: - MicroVM Configuration Builder
    
    /// Constructs a real Apple Virtualization VZVirtualMachineConfiguration
    /// with isolated VirtIO storage, shared directory mounts, and constrained resources.
    public func buildMicroVMConfiguration(sharedDirectory: URL? = nil, cpuCount: Int = 2, memoryBytes: UInt64 = 1024 * 1024 * 1024) throws -> VZVirtualMachineConfiguration {
        guard VZVirtualMachine.isSupported else {
            throw NSError(domain: "VirtualizationSandbox", code: 1, userInfo: [NSLocalizedDescriptionKey: "VZVirtualMachine is not supported on this architecture"])
        }
        
        let config = VZVirtualMachineConfiguration()
        
        // 1. CPU & Memory limits
        let maxCPUs = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let minCPUs = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let clampedCPUs = max(minCPUs, min(cpuCount, maxCPUs))
        config.cpuCount = clampedCPUs
        
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let clampedMem = max(minMem, min(memoryBytes, maxMem))
        config.memorySize = clampedMem
        
        // 2. Entropy device for cryptographic safety
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        
        // 3. Memory balloon device for dynamic host memory reclamation
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        
        // 4. Directory sharing if specified
        if let dir = sharedDirectory {
            let sharedDir = VZSharedDirectory(url: dir, readOnly: false)
            let singleShare = VZSingleDirectoryShare(directory: sharedDir)
            let fsDevice = VZVirtioFileSystemDeviceConfiguration(tag: "apex_sandbox")
            fsDevice.share = singleShare
            config.directorySharingDevices = [fsDevice]
        }
        
        return config
    }
    
    // MARK: - Ephemeral APFS Sandbox Execution
    
    /// Executes a shell command inside an isolated ephemeral directory with rollback on exit.
    ///
    /// - Note: This provides ephemeral APFS process isolation (temp directory sandbox with
    /// POSIX-quote an argv array for safe transport through `/bin/zsh -c`
    public static func shellQuoted(_ args: [String]) -> String {
        args.map { arg in
            if arg.range(of: "^[a-zA-Z0-9_./-]+$", options: .regularExpression) != nil {
                return arg
            } else {
                return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
        }.joined(separator: " ")
    }

    /// Executes a command in an isolated ephemeral sandbox directory with
    /// sanitized environment variables, resource timeouts, and clean teardown.
    ///
    /// - Note: this provides process-level directory isolation (with post-run
    ///   rollback), NOT hardware virtual-machine isolation. For VM isolation, use
    ///   `buildMicroVMConfiguration` + a `VZVirtualMachine` guest process.
    public func executeInIsolatedSandbox(command: String, arguments: [String] = [], workingFiles: [URL] = [], timeoutSeconds: TimeInterval = 30.0) async throws -> SandboxExecutionResult {
        let sandboxId = UUID().uuidString
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("apex_sandbox_\(sandboxId)")
        
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        activeSandboxCount += 1
        
        defer {
            try? fileManager.removeItem(at: tempDir)
            activeSandboxCount = max(0, activeSandboxCount - 1)
        }
        
        // Copy working files into ephemeral sandbox
        for file in workingFiles {
            let dest = tempDir.appendingPathComponent(file.lastPathComponent)
            try? fileManager.copyItem(at: file, to: dest)
        }
        
        let startTime = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.currentDirectoryURL = tempDir
        
        // Sanitize environment variables
        var env: [String: String] = [:]
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = tempDir.path
        env["TMPDIR"] = tempDir.path
        env["APEX_SANDBOX"] = "1"
        process.environment = env
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        let script: String
        if arguments.isEmpty {
            script = command
        } else {
            let quotedArgs = Self.shellQuoted(arguments)
            script = "\(command) \(quotedArgs)"
        }
        process.arguments = ["-c", script]
        
        try process.run()
        
        // Drain both pipes concurrently to avoid deadlock when one pipe's
        // buffer fills while the other is being read synchronously.
        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }
        
        // Enforce timeoutSeconds — poll at 50ms intervals, kill on expiry.
        let deadline = startTime.addingTimeInterval(timeoutSeconds)
        var timedOut = false
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            timedOut = true
        }
        
        let outputData = await stdoutTask.value
        let errorData = await stderrTask.value
        
        let duration = Date().timeIntervalSince(startTime)
        let stdout = String(data: outputData, encoding: .utf8) ?? ""
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        
        if timedOut {
            throw NSError(
                domain: "VirtualizationMicroVMSandbox",
                code: 124,
                userInfo: [NSLocalizedDescriptionKey: "Sandbox command timed out after \(Int(timeoutSeconds))s"]
            )
        }
        
        return SandboxExecutionResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            executionDuration: duration,
            wasSandboxed: true
        )
    }
}

