import Foundation
import Darwin

@_silgen_name("forkpty")
func sys_forkpty(_ amaster: UnsafeMutablePointer<Int32>, _ name: UnsafeMutablePointer<CChar>?, _ termp: UnsafeRawPointer?, _ winp: UnsafeRawPointer?) -> pid_t

public protocol ContainerInteractiveSession: Sendable {
    func write(_ text: String)
    func kill() async
}

@MainActor
public protocol ContainerManagerProtocol: Sendable {
    var stateDescription: String { get }
    var containerCPUs: Int { get }
    var containerMemoryMB: Int { get }
    var appleContainerImage: String { get }

    func startContainer() async throws
    func stopContainer() async throws

    func startInteractiveShell(
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) async throws -> any ContainerInteractiveSession
    
    func exec(_ command: String) async throws -> (output: String, exitCode: Int32)
}

public final class ContainerBridge: @unchecked Sendable {
    @MainActor public static var shared: (any ContainerManagerProtocol)?
}

class PTYSession: @unchecked Sendable {
    private var masterFd: Int32 = -1
    private var childPid: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let outputQueue = DispatchQueue(label: "com.apexagent.pty.read")
    
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    let orchestrator: OrchestratorProvider?
    
    // Command tracking state
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var accumulatedOutput = ""
    private var currentMarker = ""
    private var pendingCommand = ""
    
    // Native Container Sandbox Session
    private var activeContainerSession: (any ContainerInteractiveSession)?
    private var isContainerMode: Bool = false
    
    private func cleanTerminalOutput(_ raw: String, originalCommand: String) -> String {
        // Strip ANSI escape sequences
        let ansiPattern = #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#
        var text = raw.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
        
        // Normalize line breaks
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        
        var lines = text.components(separatedBy: "\n")
        
        // Remove lines that correspond to shell prompt or wrapper invocation echo
        // e.g. "{", "}", "echo ...", zsh prompt lines like "% user@host path %"
        let cmdLines = Set(originalCommand.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        
        while let first = lines.first {
            let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "{" || trimmed == "}" || trimmed.hasPrefix("echo \"") || trimmed.contains("____APEX_CMD_DONE_") || cmdLines.contains(trimmed) || (trimmed.contains("%") && trimmed.contains("@")) {
                lines.removeFirst()
            } else {
                break
            }
        }
        
        while let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "}" || trimmed.hasPrefix("echo \"") || trimmed.contains("____APEX_CMD_DONE_") {
                lines.removeLast()
            } else {
                break
            }
        }
        
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func processContinuationOutput(_ str: String) {
        if self.pendingContinuation != nil {
            self.accumulatedOutput += str
            
            // Fast tail search: the marker is appended only when the command completes,
            // so it will always appear near the end of accumulated output.
            // Bounding the search window avoids O(N^2) grapheme cluster scanning on high-throughput output.
            let lookback = min(self.accumulatedOutput.count, str.count + self.currentMarker.count + 256)
            let searchStartIndex = self.accumulatedOutput.index(self.accumulatedOutput.endIndex, offsetBy: -lookback)
            
            if let range = self.accumulatedOutput.range(of: self.currentMarker, options: .backwards, range: searchStartIndex..<self.accumulatedOutput.endIndex) {
                let outputBeforeMarker = String(self.accumulatedOutput[..<range.lowerBound])
                let outputAfterMarker = String(self.accumulatedOutput[range.upperBound...])
                
                // Extract the exit code following the marker
                let cleanAfter = outputAfterMarker.trimmingCharacters(in: .whitespacesAndNewlines)
                let exitCodeStr = cleanAfter.components(separatedBy: .whitespacesAndNewlines).first ?? "0"
                let exitCode = Int32(exitCodeStr) ?? 0
                
                let cleaned = cleanTerminalOutput(outputBeforeMarker, originalCommand: self.pendingCommand)
                let finalOutput = cleaned.isEmpty ? outputBeforeMarker.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
                let continuation = self.pendingContinuation
                
                self.pendingContinuation = nil
                self.currentMarker = ""
                self.accumulatedOutput = ""
                self.pendingCommand = ""
                
                if exitCode == 0 {
                    continuation?.resume(returning: finalOutput)
                } else {
                    continuation?.resume(throwing: NSError(domain: "PTYSession", code: Int(exitCode), userInfo: [
                        NSLocalizedDescriptionKey: "Command failed with exit code \(exitCode)",
                        "output": finalOutput
                    ]))
                }
            } else if self.accumulatedOutput.count > 256_000 {
                // Keep head and tail to prevent uncontrolled memory inflation on giant commands (e.g. ls -R)
                let keepHead = 64_000
                let keepTail = 64_000
                let head = self.accumulatedOutput.prefix(keepHead)
                let tail = self.accumulatedOutput.suffix(keepTail)
                self.accumulatedOutput = head + "\n\n[... terminal output truncated ...]\n\n" + tail
            }
        }
    }
    
    init(workspacePath: String? = nil, orchestrator: OrchestratorProvider? = nil) async throws {
        let dockerEnabled = UserDefaults.standard.bool(forKey: "apex.dockerSandboxingEnabled")
        let dockerImage = UserDefaults.standard.string(forKey: "apex.dockerImage") ?? "swift:latest"
        
        let appleContainersEnabled = UserDefaults.standard.bool(forKey: "apex.appleContainersEnabled")
        
        self.orchestrator = orchestrator
        
        let isRestricted = await MainActor.run { orchestrator?.orchestrator.isFolderAccessRestricted() ?? false }
        
        var shellPath = "/bin/zsh"
        var shellArgs = [shellPath]
        
        var isDockerTestFallback = false
        var isAppleContainerTestFallback = false
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "apex.testDockerFallback") {
            isDockerTestFallback = true
        }
        if UserDefaults.standard.bool(forKey: "apex.testAppleContainerFallback") {
            isAppleContainerTestFallback = true
        }
        #endif
        
        if appleContainersEnabled && !isAppleContainerTestFallback {
            do {
                guard let manager = await ContainerBridge.shared else {
                    throw NSError(domain: "PTYSession", code: -5, userInfo: [NSLocalizedDescriptionKey: "Apple Container Sandbox is not supported in this target"])
                }
                // Initialize via native ContainerManager
                let session = try await manager.startInteractiveShell(
                    onOutput: { [weak self] (text: String) in
                        guard let self = self else { return }
                        self.onOutput?(text)
                        self.outputQueue.async {
                            self.processContinuationOutput(text)
                        }
                    },
                    onExit: { [weak self] (code: Int32) in
                        guard let self = self else { return }
                        self.cleanup()
                        self.onExit?(code)
                    }
                )
                self.activeContainerSession = session
                self.isContainerMode = true
                self.masterFd = -999 // indicator flag
                return
            } catch {
                let failureReason = error.localizedDescription
                // M10: this catch used to fail open with only a console
                // print — a sandbox that never started left the user
                // believing they were isolated. Warn loudly (console +
                // terminal UI); strict isolation forbids the host fallback
                // entirely and rethrows instead of executing unconfined.
                let strictMode = await (ContainerBridge.shared as? ContainerManager)?.isolationLevel == .strict
                print("🚨 [PTYSession] SECURITY: Apple Container sandbox failed to start (\(failureReason)). " +
                      (strictMode
                        ? "Strict isolation forbids falling back to a host PTY — refusing to start."
                        : "Falling back to a HOST PTY: commands will run WITHOUT container isolation."))
                if let provider = orchestrator {
                    await MainActor.run {
                        provider.orchestrator.activeTerminalOutput +=
                            "\n⚠️ Container sandbox failed to start (\(failureReason)). " +
                            (strictMode
                                ? "Strict isolation forbids the host fallback — this session did not start."
                                : "This terminal is running ON THE HOST without container isolation.") + "\n"
                    }
                }
                if strictMode {
                    throw NSError(domain: "PTYSession", code: -7, userInfo: [
                        NSLocalizedDescriptionKey: "Apple Container sandbox failed to start (\(failureReason)); strict isolation forbids falling back to host PTY."
                    ])
                }
                // Fall back to host PTY session rather than failing shell command execution
            }
        } else if dockerEnabled && !isDockerTestFallback {
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
                throw NSError(domain: "PTYSession", code: -6, userInfo: [
                    NSLocalizedDescriptionKey: "Docker Sandboxing is enabled, but the 'docker' binary was not found in common paths."
                ])
            }
        }
        
        // Pre-allocate shellPath, arguments, and environment in the parent thread.
        let cShellPath = strdup(shellPath)
        let cWorkspacePath = workspacePath.flatMap { strdup($0) }
        
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
        if env["DEVELOPER_DIR"] == nil,
           FileManager.default.fileExists(atPath: "/Applications/Xcode-beta.app/Contents/Developer") {
            env["DEVELOPER_DIR"] = "/Applications/Xcode-beta.app/Contents/Developer"
        }
        
        if isRestricted {
            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser
            let sandboxDir = homeDir.appendingPathComponent(".apex/sandbox")
            try? fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)
            let zshrc = sandboxDir.appendingPathComponent(".zshrc")
            if !fm.fileExists(atPath: zshrc.path) {
                try? "# Bypass zsh new user menu".write(to: zshrc, atomically: true, encoding: .utf8)
            }
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
            if let cWorkspacePath = cWorkspacePath { free(cWorkspacePath) }
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
            // Child Process: Only call async-signal-safe functions (execve, chdir, exit)
            var t = termios()
            if tcgetattr(STDIN_FILENO, &t) == 0 {
                t.c_lflag &= ~tcflag_t(ECHO)
                tcsetattr(STDIN_FILENO, TCSANOW, &t)
            }
            
            // Set CWD to workspace so commands run in the right directory
            if let ws = cWorkspacePath {
                chdir(ws)
            }
            
            if let path = cShellPath {
                execve(path, argv, envp)
            }
            _exit(1)
        } else {
            // Parent Process (Success): Clean up parent's copy of allocated C strings
            if let cShellPath = cShellPath { free(cShellPath) }
            if let cWorkspacePath = cWorkspacePath { free(cWorkspacePath) }
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
                    self.processContinuationOutput(str)
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
        if isContainerMode, let session = activeContainerSession {
            session.write(command)
            return
        }
        guard masterFd >= 0 else { return }
        guard let data = command.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                var bytesWritten = 0
                while bytesWritten < data.count {
                    let result = Darwin.write(masterFd, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                    if result <= 0 { break } // fd closed or error
                    bytesWritten += result
                }
            }
        }
    }
    
    func runCommand(_ command: String) async throws -> String {
        if isContainerMode {
            guard let manager = await ContainerBridge.shared else {
                throw NSError(domain: "PTYSession", code: -5, userInfo: [NSLocalizedDescriptionKey: "Apple Container Sandbox is not supported in this target"])
            }
            let (output, exitCode) = try await manager.exec(command)
            if exitCode != 0 {
                throw NSError(domain: "PTYSession", code: Int(exitCode), userInfo: [
                    NSLocalizedDescriptionKey: output.isEmpty ? "Process exited with code \(exitCode)" : output,
                    "output": output
                ])
            }
            return output
        }
        
        guard masterFd >= 0 else {
            throw NSError(domain: "PTYSession", code: -4, userInfo: [NSLocalizedDescriptionKey: "Shell session is not running"])
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outputQueue.async {
                    guard self.isContainerMode || self.masterFd >= 0 else {
                        continuation.resume(throwing: NSError(domain: "PTYSession", code: -4, userInfo: [NSLocalizedDescriptionKey: "Shell session was terminated"]))
                        return
                    }
                    if let oldContinuation = self.pendingContinuation {
                        self.pendingContinuation = nil
                        oldContinuation.resume(throwing: NSError(domain: "PTYSession", code: -2, userInfo: [NSLocalizedDescriptionKey: "Command cancelled by subsequent execution"]))
                    }
                    
                    self.accumulatedOutput = ""
                    self.pendingCommand = command
                    let uniqueId = UUID().uuidString.prefix(8)
                    let markerPrefix = "____APEX_CMD_DONE_"
                    let markerSuffix = "\(uniqueId)____"
                    self.currentMarker = "\(markerPrefix)\(markerSuffix)"
                    self.pendingContinuation = continuation
                    
                    // Write command wrapped in a block, print exit code, and trigger carriage return.
                    // Split the marker string literal in the command payload so the terminal's command echo
                    // does not prematurely match the currentMarker before the command actually executes.
                    let fullCommand = "\n{\n" + command + "\n}\necho \"\\n\(markerPrefix)\"\"\(markerSuffix) $?\"\n"
                    self.write(command: fullCommand)
                }
            }
        } onCancel: {
            outputQueue.async {
                // Send SIGINT (Ctrl+C) to terminate the running command in the PTY
                self.write(command: "\u{0003}")
                if let continuation = self.pendingContinuation {
                    self.pendingContinuation = nil
                    self.currentMarker = ""
                    self.accumulatedOutput = ""
                    self.pendingCommand = ""
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
    
    func cleanup() {
        if isContainerMode {
            isContainerMode = false
            let session = activeContainerSession
            activeContainerSession = nil
            Task {
                await session?.kill()
            }
        }
        
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
