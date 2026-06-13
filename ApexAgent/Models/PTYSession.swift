import Foundation
import Darwin

@_silgen_name("forkpty")
func sys_forkpty(_ amaster: UnsafeMutablePointer<Int32>, _ name: UnsafeMutablePointer<CChar>?, _ termp: UnsafeRawPointer?, _ winp: UnsafeRawPointer?) -> pid_t

class PTYSession: @unchecked Sendable {
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let outputQueue = DispatchQueue(label: "com.apexagent.pty.read")
    
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    
    // Command tracking state
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var accumulatedOutput = ""
    private var currentMarker = ""
    
    init(workspacePath: String? = nil) throws {
        let dockerEnabled = UserDefaults.standard.bool(forKey: "apex.dockerSandboxingEnabled")
        let dockerImage = UserDefaults.standard.string(forKey: "apex.dockerImage") ?? "swift:latest"
        
        var shellPath = "/bin/zsh"
        var shellArgs = [shellPath]
        var warningMessage: String? = nil
        
        var isTestFallback = false
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "apex.testDockerFallback") {
            isTestFallback = true
        }
        #endif
        
        if dockerEnabled && !isTestFallback {
            let fm = FileManager.default
            let dockerPaths = [
                "/usr/local/bin/docker",
                "/opt/homebrew/bin/docker",
                "/usr/bin/docker"
            ]
            
            if let foundDocker = dockerPaths.first(where: { fm.fileExists(atPath: $0) }) {
                let workspace = workspacePath ?? fm.currentDirectoryPath
                shellPath = foundDocker
                shellArgs = [
                    shellPath,
                    "run",
                    "-it",
                    "--rm",
                    "-v", "\(workspace):\(workspace)",
                    "-w", workspace,
                    dockerImage,
                    "/bin/sh"
                ]
            } else {
                warningMessage = "\r\n⚠️  WARNING: Docker Sandboxing is enabled, but the 'docker' binary was not found in common paths.\r\n⚠️  Falling back to local shell.\r\n\r\n"
            }
        }
        
        // Pre-allocate shellPath, arguments, and environment in the parent thread.
        let cShellPath = strdup(shellPath)
        
        let argsCount = shellArgs.count
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: argsCount + 1)
        for i in 0..<argsCount {
            argv[i] = strdup(shellArgs[i])
        }
        argv[argsCount] = nil
        
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-color"
        env["NO_COLOR"] = "1"
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + currentPath
        
        if AgentOrchestrator.isFolderAccessRestricted() {
            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser
            let sandboxDir = homeDir.appendingPathComponent(".apex/sandbox")
            try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
            env["HOME"] = sandboxDir.path
        }
        
        let envList = env.map { "\($0.key)=\($0.value)" }
        let envCount = envList.count
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: envCount + 1)
        for i in 0..<envCount {
            envp[i] = strdup(envList[i])
        }
        envp[envCount] = nil
        
        var master: Int32 = -1
        let pid = sys_forkpty(&master, nil, nil, nil)
        
        if pid < 0 {
            // Parent (Failure): Clean up pre-allocated C strings
            if let cShellPath = cShellPath { free(cShellPath) }
            for i in 0..<argsCount {
                if let ptr = argv[i] { free(ptr) }
            }
            argv.deallocate()
            
            for i in 0..<envCount {
                if let ptr = envp[i] { free(ptr) }
            }
            envp.deallocate()
            
            throw NSError(domain: "PTYSession", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "forkpty failed"])
        } else if pid == 0 {
            // Child Process: Only call async-signal-safe functions (execve, exit)
            var t = termios()
            if tcgetattr(STDIN_FILENO, &t) == 0 {
                t.c_lflag &= ~tcflag_t(ECHO)
                tcsetattr(STDIN_FILENO, TCSANOW, &t)
            }
            
            if let path = cShellPath {
                execve(path, argv, envp)
            }
            exit(1)
        } else {
            // Parent Process (Success): Clean up parent's copy of allocated C strings
            if let cShellPath = cShellPath { free(cShellPath) }
            for i in 0..<argsCount {
                if let ptr = argv[i] { free(ptr) }
            }
            argv.deallocate()
            
            for i in 0..<envCount {
                if let ptr = envp[i] { free(ptr) }
            }
            envp.deallocate()
            
            self.masterFd = master
            self.childPid = pid
            
            let flags = fcntl(masterFd, F_GETFL, 0)
            _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)
            
            setupReadSource()
            
            if let warning = warningMessage {
                DispatchQueue.main.async {
                    self.onOutput?(warning)
                }
            }
        }
    }
    
    private func setupReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFd, queue: outputQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            let bufferSize = 4096
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            let bytesRead = read(self.masterFd, &buffer, bufferSize)
            
            if bytesRead > 0 {
                let data = Data(buffer.prefix(bytesRead))
                if let str = String(data: data, encoding: .utf8) {
                    // 1. Deliver to general console listener
                    self.onOutput?(str)
                    
                    // 2. Process active command continuation
                    if self.pendingContinuation != nil {
                        self.accumulatedOutput += str
                        
                        if let range = self.accumulatedOutput.range(of: self.currentMarker) {
                            let outputBeforeMarker = String(self.accumulatedOutput[..<range.lowerBound])
                            let outputAfterMarker = String(self.accumulatedOutput[range.upperBound...])
                            
                            // Extract the exit code following the marker
                            let cleanAfter = outputAfterMarker.trimmingCharacters(in: .whitespacesAndNewlines)
                            let exitCodeStr = cleanAfter.components(separatedBy: .whitespacesAndNewlines).first ?? "0"
                            let exitCode = Int32(exitCodeStr) ?? 0
                            
                            let finalOutput = outputBeforeMarker.trimmingCharacters(in: .whitespacesAndNewlines)
                            let continuation = self.pendingContinuation
                            
                            self.pendingContinuation = nil
                            self.currentMarker = ""
                            self.accumulatedOutput = ""
                            
                            if exitCode == 0 {
                                continuation?.resume(returning: finalOutput)
                            } else {
                                continuation?.resume(throwing: NSError(domain: "PTYSession", code: Int(exitCode), userInfo: [
                                    NSLocalizedDescriptionKey: "Command failed with exit code \(exitCode)",
                                    "output": finalOutput
                                ]))
                            }
                        }
                    }
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN) {
                self.cleanup()
                self.onExit?(0)
            }
        }
        
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.masterFd >= 0 {
                close(self.masterFd)
                self.masterFd = -1
            }
        }
        
        readSource = source
        source.resume()
    }
    
    func write(command: String) {
        guard masterFd >= 0 else { return }
        guard let data = command.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                _ = Darwin.write(masterFd, baseAddress, data.count)
            }
        }
    }
    
    func runCommand(_ command: String) async throws -> String {
        guard masterFd >= 0 else {
            throw NSError(domain: "PTYSession", code: -4, userInfo: [NSLocalizedDescriptionKey: "Shell session is not running"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            outputQueue.async {
                guard self.masterFd >= 0 else {
                    continuation.resume(throwing: NSError(domain: "PTYSession", code: -4, userInfo: [NSLocalizedDescriptionKey: "Shell session was terminated"]))
                    return
                }
                if let oldContinuation = self.pendingContinuation {
                    self.pendingContinuation = nil
                    oldContinuation.resume(throwing: NSError(domain: "PTYSession", code: -2, userInfo: [NSLocalizedDescriptionKey: "Command cancelled by subsequent execution"]))
                }
                
                self.accumulatedOutput = ""
                let uniqueId = UUID().uuidString.prefix(8)
                self.currentMarker = "____APEX_CMD_DONE_\(uniqueId)____"
                self.pendingContinuation = continuation
                
                // Write command, print exit code, and trigger carriage return
                let fullCommand = command + "; echo \"\\n\(self.currentMarker) $?\"\n"
                self.write(command: fullCommand)
            }
        }
    }
    
    func cleanup() {
        readSource?.cancel()
        readSource = nil
        
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(throwing: NSError(domain: "PTYSession", code: -3, userInfo: [NSLocalizedDescriptionKey: "PTY session was terminated or cleaned up"]))
        }
        
        if childPid > 0 {
            kill(childPid, SIGKILL)
            var status: Int32 = 0
            waitpid(childPid, &status, WNOHANG)
            childPid = -1
        }
    }
    
    deinit {
        cleanup()
    }
}
