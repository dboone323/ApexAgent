import Foundation
import Observation
import Containerization
import ContainerizationOCI
import ContainerizationArchive
import ContainerizationOS
import Logging

extension InteractiveSession: ContainerInteractiveSession {}

@Observable
@MainActor
public final class ContainerManager: Sendable, ContainerManagerProtocol {
    public static let shared = ContainerManager()
    
    public enum State: Sendable, Equatable {
        case idle
        case downloadingKernel(Double)
        case pullingImage(Double)
        case starting
        case running
        case stopping
        case errored(String)
        
        public var description: String {
            switch self {
            case .idle: return "Idle"
            case .downloadingKernel(let progress): return "Downloading Kernel (\(Int(progress * 100))%)"
            case .pullingImage(let progress): return "Pulling Image (\(Int(progress * 100))%)"
            case .starting: return "Starting Sandbox..."
            case .running: return "Sandbox Running"
            case .stopping: return "Stopping Sandbox..."
            case .errored(let msg): return "Error: \(msg)"
            }
        }
    }
    
    public var state: State = .idle
    
    public var stateDescription: String {
        get { self.state.description }
    }
    
    // Core settings synced with UserDefaults
    public var appleContainerImage: String {
        get { UserDefaults.standard.string(forKey: "apex.appleContainerImage") ?? "swift:latest" }
        set { UserDefaults.standard.set(newValue, forKey: "apex.appleContainerImage") }
    }
    
    public var containerCPUs: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "apex.containerCPUs")
            return val > 0 ? val : 4
        }
        set { UserDefaults.standard.set(newValue, forKey: "apex.containerCPUs") }
    }
    
    public var containerMemoryMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "apex.containerMemoryMB")
            return val > 0 ? val : 1024
        }
        set { UserDefaults.standard.set(newValue, forKey: "apex.containerMemoryMB") }
    }
    
    // Paths
    private let appRoot: URL = {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let root = paths.first!.appendingPathComponent("com.apexagent.containers")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()
    
    private var kernelPath: URL {
        appRoot.appendingPathComponent("kernel/vmlinux")
    }
    
    private var imageStore: ImageStore?
    private var container: LinuxContainer?
    private var containerManager: Containerization.ContainerManager?
    private var interactiveShell: LinuxProcess?
    private var stdinPipe: PipeReaderStream?
    
    private let logger = Logger(label: "com.apexagent.containermanager")
    
    private init() {
        // Initialize image store location
        do {
            let storeURL = appRoot.appendingPathComponent("imagestore")
            try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
            self.imageStore = try ImageStore(path: storeURL)
        } catch {
            self.logger.error("Failed to initialize ImageStore: \(error)")
            self.state = .errored("Failed to initialize image store: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Kernel download
    private func ensureKernel() async throws -> URL {
        let dest = kernelPath
        if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
            return dest
        }
        
        state = .downloadingKernel(0.0)
        let kernelDir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: kernelDir, withIntermediateDirectories: true)
        
        let tarballURL = kernelDir.appendingPathComponent("kata.tar.xz")
        // NOTE: Containerization is Apple-Silicon (arm64) only. This kernel asset
        // is a pinned arm64 build (Kata Containers 3.17.0). If bumping the version,
        // update both this URL and the extracted path below, and keep it arm64.
        let defaultKernelURL = "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
        
        do {
            try await downloadFile(from: defaultKernelURL, to: tarballURL) { [weak self] progress in
                guard let self = self else { return }
                self.state = .downloadingKernel(progress)
            }
            
            // Extract using tar subprocess to handle BSD tar directly
            let tempDir = kernelDir.appendingPathComponent("temp_extract")
            try? FileManager.default.removeItem(at: tempDir)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [
                "-xf", tarballURL.path(percentEncoded: false),
                "-C", tempDir.path(percentEncoded: false),
                "opt/kata/share/kata-containers/vmlinux.container"
            ]
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ContainerManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "tar extraction failed"])
            }
            
            let extractedFile = tempDir.appendingPathComponent("opt/kata/share/kata-containers/vmlinux.container")
            if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
                try? FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: extractedFile, to: dest)
            
            // Cleanup
            try? FileManager.default.removeItem(at: tarballURL)
            try? FileManager.default.removeItem(at: tempDir)
            
            return dest
        } catch {
            try? FileManager.default.removeItem(at: tarballURL)
            let isNetworkError = (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain
            let userMsg = isNetworkError 
                ? "Sandbox setup requires internet connection to download Linux kernel and images on first run. Please connect to the internet and try again." 
                : "Failed to resolve Linux kernel: \(error.localizedDescription)"
            state = .errored(userMsg)
            throw NSError(domain: "ContainerManager", code: -7, userInfo: [NSLocalizedDescriptionKey: userMsg, NSUnderlyingErrorKey: error])
        }
    }
    
    private func downloadFile(from urlString: String, to destination: URL, onProgress: @escaping (Double) -> Void) async throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        
        // Simpler async download for file
        let (tempURL, response) = try await session.download(from: url)
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw NSError(domain: "ContainerManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP status code \(httpResponse.statusCode)"])
        }
        
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
    
    // MARK: - Lifecycle Management
    
    public func startContainer() async throws {
        if state == .running { return }
        
        state = .starting
        do {
            let resolvedKernelPath = try await ensureKernel()
            let kernel = Kernel(path: resolvedKernelPath, platform: .linuxArm)
            
            guard let store = self.imageStore else {
                throw NSError(domain: "ContainerManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image store not initialized"])
            }
            
            // Choose network based on macOS version
            var network: Network? = nil
            if #available(macOS 26, *) {
                do {
                    network = try VmnetNetwork()
                } catch {
                    self.logger.warning("Failed to initialize VmnetNetwork (continuing without networking): \(error)")
                }
            }
            
            // Initialize the Apple ContainerManager library wrapper.
            // NOTE: Containerization is Apple-Silicon (arm64) only. This initfs is a
            // pinned Apple vminit asset (0.30.0); keep this reference in sync with the
            // Containerization package version when upgrading.
            let initfsRef = "ghcr.io/apple/containerization/vminit:0.30.0"
            
            // Pull the initfs if not present
            state = .pullingImage(0.0)
            do {
                _ = try await store.getInitImage(reference: initfsRef)
            } catch {
                let isNetworkError = (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain
                let userMsg = isNetworkError 
                    ? "Sandbox setup requires internet connection to pull the initfs image on first run. Please connect to the internet and try again." 
                    : "Failed to pull initfs image: \(error.localizedDescription)"
                state = .errored(userMsg)
                throw NSError(domain: "ContainerManager", code: -8, userInfo: [NSLocalizedDescriptionKey: userMsg, NSUnderlyingErrorKey: error])
            }
            state = .pullingImage(1.0)
            
            var mgr = try await Containerization.ContainerManager(
                kernel: kernel,
                initfsReference: initfsRef,
                imageStore: store,
                network: network
            )
            
            state = .starting
            
            // Unpack target container workload image (default alpine or swift)
            let imageRef = appleContainerImage
            state = .pullingImage(0.0)
            let image: Containerization.Image
            do {
                image = try await store.get(reference: imageRef, pull: true)
            } catch {
                let isNetworkError = (error as? URLError) != nil || (error as NSError).domain == NSURLErrorDomain
                let userMsg = isNetworkError 
                    ? "Sandbox setup requires internet connection to pull container image '\(imageRef)' on first run. Please connect to the internet and try again." 
                    : "Failed to pull container image '\(imageRef)': \(error.localizedDescription)"
                state = .errored(userMsg)
                throw NSError(domain: "ContainerManager", code: -9, userInfo: [NSLocalizedDescriptionKey: userMsg, NSUnderlyingErrorKey: error])
            }
            
            let containerId = "apex-sandbox"
            
            // Recreate container folder
            let containerPath = appRoot.appendingPathComponent("containers").appendingPathComponent(containerId)
            try? FileManager.default.removeItem(at: containerPath)
            
            let cpus = containerCPUs
            let memory = containerMemoryMB
            let workspace = FileManager.default.currentDirectoryPath
            
            // Create container
            let containerInstance = try await mgr.create(
                containerId,
                image: image,
                rootfsSizeInBytes: 4096 * 1024 * 1024, // 4GB workspace rootfs size
                networking: network != nil
            ) { @Sendable config in
                config.cpus = cpus
                config.memoryInBytes = UInt64(memory) * 1024 * 1024
                
                // Mount current directory/workspace
                let czMount = Containerization.Mount.share(
                    source: workspace,
                    destination: workspace
                )
                config.mounts.append(czMount)
            }
            
            try await containerInstance.create()
            try await containerInstance.start()
            
            self.container = containerInstance
            self.containerManager = mgr
            self.state = .running
            self.logger.info("Sandbox container started successfully.")
        } catch {
            self.state = .errored("Failed to start container: \(error.localizedDescription)")
            throw error
        }
    }
    
    public func stopContainer() async throws {
        guard state == .running else { return }
        state = .stopping
        
        interactiveShell = nil
        stdinPipe = nil
        
        do {
            if let active = container {
                try await active.stop()
                try? containerManager?.delete("apex-sandbox")
            }
            container = nil
            containerManager = nil
            state = .idle
        } catch {
            state = .errored("Failed to stop container: \(error.localizedDescription)")
            throw error
        }
    }
    
    // MARK: - Process Execution
    
    public func startInteractiveShell(
        onOutput: @Sendable @escaping (String) -> Void,
        onExit: @Sendable @escaping (Int32) -> Void
    ) async throws -> any ContainerInteractiveSession {
        // Ensure container is running
        try await startContainer()
        
        guard let active = container else {
            throw NSError(domain: "ContainerManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Container not running"])
        }
        
        let pipe = PipeReaderStream()
        self.stdinPipe = pipe
        
        let stdoutWriter = CallbackWriter { data in
            if let text = String(data: data, encoding: .utf8) {
                onOutput(text)
            }
        }
        
        var shellConfig = LinuxProcessConfiguration()
        shellConfig.arguments = ["/bin/sh", "-i"]
        shellConfig.workingDirectory = FileManager.default.currentDirectoryPath
        shellConfig.terminal = true
        shellConfig.stdin = pipe
        shellConfig.stdout = stdoutWriter
        shellConfig.stderr = stdoutWriter
        
        let process = try await active.exec("interactive-shell", configuration: shellConfig)
        try await process.start()
        self.interactiveShell = process
        
        // Handle termination asynchronously
        Task.detached {
            do {
                let status = try await process.wait()
                onExit(Int32(status.exitCode))
            } catch {
                onExit(-1)
            }
        }
        
        return InteractiveSession(pipe: pipe, process: process)
    }
    
    public func exec(_ command: String) async throws -> (output: String, exitCode: Int32) {
        try await exec(command, workingDirectory: nil)
    }
    
    public func exec(_ command: String, workingDirectory: String? = nil) async throws -> (output: String, exitCode: Int32) {
        guard state == .running, let active = container else {
            throw NSError(domain: "ContainerManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Container is not running"])
        }
        
        let collector = DataCollector()
        
        var processConfig = LinuxProcessConfiguration()
        processConfig.arguments = ["/bin/sh", "-c", command]
        processConfig.workingDirectory = workingDirectory ?? FileManager.default.currentDirectoryPath
        processConfig.terminal = false
        processConfig.stdout = collector
        processConfig.stderr = collector
        
        let process = try await active.exec(UUID().uuidString, configuration: processConfig)
        try await process.start()
        
        let exitStatus = try await process.wait()
        let output = collector.string()
        return (output: output, exitCode: Int32(exitStatus.exitCode))
    }
}

// MARK: - Interactive Shell Session Helper

public struct InteractiveSession: Sendable {
    private let pipe: PipeReaderStream
    private let process: LinuxProcess
    
    init(pipe: PipeReaderStream, process: LinuxProcess) {
        self.pipe = pipe
        self.process = process
    }
    
    public func write(_ text: String) {
        if let data = text.data(using: .utf8) {
            pipe.write(data)
        }
    }
    
    public func resize(width: UInt16, height: UInt16) async {
        let size = Terminal.Size(width: width, height: height)
        try? await process.resize(to: size)
    }
    
    public func kill() async {
        try? await process.kill(.kill)
    }
}

// MARK: - Helper I/O Implementations

final class CallbackWriter: Writer, @unchecked Sendable {
    private let onWrite: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void
    
    init(onWrite: @Sendable @escaping (Data) -> Void, onClose: @Sendable @escaping () -> Void = {}) {
        self.onWrite = onWrite
        self.onClose = onClose
    }
    
    func write(_ data: Data) throws {
        onWrite(data)
    }
    
    func close() throws {
        onClose()
    }
}

final class PipeReaderStream: ReaderStream, @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let asyncStream: AsyncStream<Data>
    
    init() {
        var cont: AsyncStream<Data>.Continuation!
        self.asyncStream = AsyncStream<Data> { cont = $0 }
        self.continuation = cont
    }
    
    func write(_ data: Data) {
        continuation.yield(data)
    }
    
    func close() {
        continuation.finish()
    }
    
    func stream() -> AsyncStream<Data> {
        return asyncStream
    }
}

final class DataCollector: Writer, @unchecked Sendable {
    private let lock = NSLock()
    private var dataBuffer = Data()
    
    func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        dataBuffer.append(data)
    }
    
    func close() throws {
        // No-op
    }
    
    func string() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: dataBuffer, encoding: .utf8) ?? ""
    }
}
