import Foundation
import Observation
import Containerization
import ContainerizationOCI
import ContainerizationArchive
import ContainerizationOS
import Logging

extension InteractiveSession: ContainerInteractiveSession {}

/// Snapshot of a container's on-disk state, used for rollback testing.
public struct ContainerSnapshotRecord: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let description: String
    public let containerId: String
    public let createdAt: Date
    public var imageRef: String?
    public var sizeInBytes: Int?
    public var isolationLevel: ContainerIsolationLevel?

    public init(id: String, name: String, containerId: String, imageRef: String? = nil, createdAt: Date = Date(), sizeInBytes: Int? = nil, isolationLevel: ContainerIsolationLevel? = nil, description: String = "") {
        self.id = id
        self.name = name
        self.containerId = containerId
        self.imageRef = imageRef
        self.createdAt = createdAt
        self.sizeInBytes = sizeInBytes
        self.isolationLevel = isolationLevel
        self.description = description
    }

    public init(id: String, name: String, description: String, containerId: String, createdAt: Date = Date(), imageRef: String? = nil, sizeInBytes: Int? = nil, isolationLevel: ContainerIsolationLevel? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.containerId = containerId
        self.createdAt = createdAt
        self.imageRef = imageRef
        self.sizeInBytes = sizeInBytes
        self.isolationLevel = isolationLevel
    }
}

/// System and hardware capability diagnostics for Apple Virtualization and containers.
public struct ContainerHostDiagnostics: Sendable, Codable, Equatable {
    public let isAppleSilicon: Bool
    public let isVirtualizationSupported: Bool
    public let macOSVersionString: String
    public let availableDiskSpaceBytes: Int64
    public let vmnetAvailable: Bool
    public let statusMessage: String

    public init(
        isAppleSilicon: Bool,
        isVirtualizationSupported: Bool,
        macOSVersionString: String,
        availableDiskSpaceBytes: Int64,
        vmnetAvailable: Bool,
        statusMessage: String
    ) {
        self.isAppleSilicon = isAppleSilicon
        self.isVirtualizationSupported = isVirtualizationSupported
        self.macOSVersionString = macOSVersionString
        self.availableDiskSpaceBytes = availableDiskSpaceBytes
        self.vmnetAvailable = vmnetAvailable
        self.statusMessage = statusMessage
    }
}

@Observable
@MainActor
public final class ContainerManager: ContainerManagerProtocol {
    public static let shared = ContainerManager()

    public static func checkHostCapabilities() -> ContainerHostDiagnostics {
        #if arch(arm64)
        let isArm = true
        #else
        let isArm = false
        #endif

        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

        var freeBytes: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? Int64 {
            freeBytes = free
        }

        var vmnet = false
        if #available(macOS 26, *) {
            vmnet = true
        }

        let supported = isArm && freeBytes > 1_000_000_000
        let status = !isArm ? "Apple Silicon (arm64) is required for native containerization."
            : (freeBytes < 1_000_000_000 ? "Low disk space (<1GB free)." : "Host system meets all virtualization requirements.")

        return ContainerHostDiagnostics(
            isAppleSilicon: isArm,
            isVirtualizationSupported: supported,
            macOSVersionString: osString,
            availableDiskSpaceBytes: freeBytes,
            vmnetAvailable: vmnet,
            statusMessage: status
        )
    }
    
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
        self.state.description
    }

    /// Isolation level for the current container runtime (used by E2E snapshot tests).
    public var isolationLevel: ContainerIsolationLevel = .standard
    
    // Core settings synced with UserDefaults
    public var appleContainerImage: String {
        get { Self.normalizeImageReference(UserDefaults.standard.string(forKey: "apex.appleContainerImage") ?? "swift:latest") }
        set { UserDefaults.standard.set(newValue, forKey: "apex.appleContainerImage") }
    }

    /// Containerization's ImageStore requires fully-qualified references
    /// (registry host + repository path). Bare Docker-Hub-style names like
    /// "swift:latest" or "alpine:3.20" fail with "invalid domain for image
    /// reference". Normalize the way the docker CLI does: no host → docker.io,
    /// no path component → library/.
    public static func normalizeImageReference(_ ref: String) -> String {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let firstComponent = trimmed.split(separator: "/", maxSplits: 1)[0]
        // A registry host contains a "." or ":" (host:port) or is "localhost".
        let hasHost = firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost"
        if hasHost && trimmed.contains("/") {
            return trimmed
        }
        if trimmed.contains("/") {
            // e.g. "user/repo:tag" → docker.io/user/repo:tag
            return "docker.io/\(trimmed)"
        }
        // e.g. "swift:latest" → docker.io/library/swift:latest
        return "docker.io/library/\(trimmed)"
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
            // Extract the whole kata-containers dir: vmlinux.container is a
            // SYMLINK inside the tarball (→ vmlinux-<ver>-<build>). Extracting
            // only the symlink member produces a broken link and no kernel.
            process.arguments = [
                "-xf", tarballURL.path(percentEncoded: false),
                "-C", tempDir.path(percentEncoded: false),
                "opt/kata/share/kata-containers"
            ]
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ContainerManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "tar extraction failed"])
            }
            
            // Resolve the symlink to the real kernel binary before moving.
            let extractedLink = tempDir.appendingPathComponent("opt/kata/share/kata-containers/vmlinux.container")
            let extractedFile = extractedLink.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: extractedFile.path(percentEncoded: false)) else {
                throw NSError(domain: "ContainerManager", code: -10, userInfo: [NSLocalizedDescriptionKey: "Extracted kernel missing: \(extractedFile.path)"])
            }
            // Remove any previous dest — including a BROKEN symlink, which
            // fileExists(atPath:) reports as absent because it traverses links.
            // moveItem would then fail with POSIX 17 "File exists".
            try? FileManager.default.removeItem(at: dest)
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
            var network: Network?
            if #available(macOS 26, *) {
                do {
                    network = try VmnetNetwork()
                } catch {
                    self.logger.warning("Failed to initialize VmnetNetwork (continuing without networking): \(error)")
                }
            }
            
            // Initialize the Apple ContainerManager library wrapper.
            // NOTE: Containerization is Apple-Silicon (arm64) only. This initfs is a
            // pinned Apple vminit asset; it MUST exactly match the host library
            // version (Package.swift pins containerization 0.38.0). vmexec's
            // sync-pipe protocol is version-coupled: a mismatched vminit fails
            // exec with "no PID data from sync pipe". Keep both pins in sync.
            let initfsRef = "ghcr.io/apple/containerization/vminit:0.38.0"
            
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
            
            // Recreate container folder. The Containerization ImageStore keeps
            // per-container state under <imagestore>/containers/<id> — NOT
            // under appRoot/containers (the old path here, which never matched
            // anything, so a crashed prior run left stale state and create()
            // failed with POSIX 17 "File exists").
            let containerPath = appRoot.appendingPathComponent("imagestore/containers").appendingPathComponent(containerId)
            try? FileManager.default.removeItem(at: containerPath)
            
            let cpus = containerCPUs
            let memory = containerMemoryMB
            let hostWorkspace: String
            let configured = UserDefaults.standard.string(forKey: "apex.workspacePath") ?? ""
            let current = FileManager.default.currentDirectoryPath
            if !configured.isEmpty && configured != "/" && configured != "." {
                hostWorkspace = NSString(string: configured).expandingTildeInPath
            } else if current != "/" && !current.isEmpty && current != "." {
                hostWorkspace = current
            } else {
                hostWorkspace = AgentOrchestrator.proactiveAuditWorkspacePath()
            }
            
            // Create container
            let containerInstance = try await mgr.create(
                containerId,
                image: image,
                rootfsSizeInBytes: 4096 * 1024 * 1024, // 4GB workspace rootfs size
                networking: network != nil
            ) { @Sendable config in
                config.cpus = cpus
                config.memoryInBytes = UInt64(memory) * 1024 * 1024
                
                // PID 1 must stay alive for the sandbox lifetime. The image
                // CMD (e.g. swift:latest → /bin/bash) exits immediately with
                // no TTY/stdin, killing the guest before any exec can run
                // ("vmexec: No such process / no PID data from sync pipe").
                // Apple's own integration tests use /bin/sleep as init.
                config.process.arguments = ["/bin/sleep", "infinity"]
                config.process.terminal = false
                
                // Mount host workspace into /workspace if valid and not system root
                if hostWorkspace != "/" && FileManager.default.fileExists(atPath: hostWorkspace) {
                    let czMount = Containerization.Mount.share(
                        source: hostWorkspace,
                        destination: "/workspace"
                    )
                    config.mounts.append(czMount)
                }
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

    // MARK: - Snapshot Management (E2E rollback testing)

    private var snapshotStore: [String: [ContainerSnapshotRecord]] = [:]

    private func snapshotsDirectory(for containerId: String) -> URL {
        appRoot.appendingPathComponent("imagestore/snapshots").appendingPathComponent(containerId)
    }

    public func createSnapshot(name: String, description: String = "", containerId: String = "default") async throws -> ContainerSnapshotRecord {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NSError(domain: "ContainerManager", code: -11, userInfo: [NSLocalizedDescriptionKey: "Snapshot name cannot be empty"])
        }

        let id = "snap-\(UUID().uuidString.prefix(8).lowercased())"
        let record = ContainerSnapshotRecord(
            id: id,
            name: name,
            description: description,
            containerId: containerId,
            createdAt: Date()
        )
        snapshotStore[containerId, default: []].append(record)

        // Persist to disk under imagestore/snapshots/<containerId>/<snap-id>/snapshot.json
        let snapDir = snapshotsDirectory(for: containerId).appendingPathComponent(id)
        let fm = FileManager.default
        try? fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        let metaURL = snapDir.appendingPathComponent("snapshot.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            try? data.write(to: metaURL)
        }

        // Backup filesystem state from imagestore/containers/<containerId>
        let containerDir = appRoot.appendingPathComponent("imagestore/containers/\(containerId)")
        let backupDir = snapDir.appendingPathComponent("fs_data")
        if fm.fileExists(atPath: containerDir.path) {
            try? fm.copyItem(at: containerDir, to: backupDir)
        }

        return record
    }

    public func restoreSnapshot(id: String, containerId: String = "default") async throws {
        let snapshots = await listSnapshots(containerId: containerId)
        guard let target = snapshots.first(where: { $0.id == id || $0.name == id }) else {
            throw NSError(domain: "ContainerManager", code: -404, userInfo: [NSLocalizedDescriptionKey: "Snapshot not found: \(id)"])
        }

        let snapDir = snapshotsDirectory(for: containerId).appendingPathComponent(target.id)
        let backupDir = snapDir.appendingPathComponent("fs_data")
        let containerDir = appRoot.appendingPathComponent("imagestore/containers/\(containerId)")
        let fm = FileManager.default

        if fm.fileExists(atPath: backupDir.path) {
            if fm.fileExists(atPath: containerDir.path) {
                try? fm.removeItem(at: containerDir)
            }
            try fm.copyItem(at: backupDir, to: containerDir)
        }
    }

    public func deleteSnapshot(id: String, containerId: String = "default") async throws {
        let snapshots = await listSnapshots(containerId: containerId)
        guard let target = snapshots.first(where: { $0.id == id || $0.name == id }) else {
            throw NSError(domain: "ContainerManager", code: -404, userInfo: [NSLocalizedDescriptionKey: "Snapshot not found: \(id)"])
        }

        snapshotStore[containerId]?.removeAll { $0.id == target.id }
        let snapDir = snapshotsDirectory(for: containerId).appendingPathComponent(target.id)
        try? FileManager.default.removeItem(at: snapDir)
    }

    public func listSnapshots(containerId: String = "default") async -> [ContainerSnapshotRecord] {
        var results: [ContainerSnapshotRecord] = snapshotStore[containerId] ?? []
        let snapBaseDir = snapshotsDirectory(for: containerId)
        let fm = FileManager.default
        if let subdirs = try? fm.contentsOfDirectory(at: snapBaseDir, includingPropertiesForKeys: nil) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for dir in subdirs {
                let metaURL = dir.appendingPathComponent("snapshot.json")
                let pathString = metaURL.path(percentEncoded: false)
                guard fm.fileExists(atPath: pathString) else { continue }
                guard let data = try? Data(contentsOf: metaURL), !data.isEmpty else { continue }
                if let record = try? decoder.decode(ContainerSnapshotRecord.self, from: data) {
                    if !results.contains(where: { $0.id == record.id }) {
                        results.append(record)
                    }
                }
            }
        }
        return results
    }

    // MARK: - Snapshot overload variants (for test compatibility)

    public func createSnapshot(name: String, containerId: String) async throws -> ContainerSnapshotRecord {
        try await createSnapshot(name: name, description: "", containerId: containerId)
    }

    public func rollbackToSnapshot(nameOrId: String, containerId: String = "default") async throws {
        try await restoreSnapshot(id: nameOrId, containerId: containerId)
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

    // MARK: - Workspace Mount Safety Guard

    public func verifyWorkspaceMountSafety(_ workspace: String) throws {
        let expanded = NSString(string: workspace).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path

        for candidate in [standardized, resolved] {
            if candidate == "/" {
                throw SecuritySandboxError.pathViolation("Mounting system directory '/' as container workspace is prohibited.")
            }

            let fm = FileManager.default
            let homeDir = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path

            // Tilde-traversal guard: if path started with ~/ but candidate escaped home directory
            if expanded.hasPrefix("~/") || expanded.hasPrefix(homeDir + "/") || expanded == homeDir {
                if !candidate.hasPrefix(homeDir + "/") && candidate != homeDir {
                    throw SecuritySandboxError.pathViolation("Escaping user home directory '\(homeDir)' is prohibited.")
                }
            }

            if candidate == homeDir {
                throw SecuritySandboxError.pathViolation("Mounting user home directory '\(homeDir)' directly as container workspace is prohibited.")
            }

            let sensitiveUserDirs: Set<String> = [
                (homeDir as NSString).appendingPathComponent("Desktop"),
                (homeDir as NSString).appendingPathComponent("Documents"),
                (homeDir as NSString).appendingPathComponent("Downloads"),
                (homeDir as NSString).appendingPathComponent("Music"),
                (homeDir as NSString).appendingPathComponent(".ssh"),
                (homeDir as NSString).appendingPathComponent(".aws"),
                (homeDir as NSString).appendingPathComponent(".gnupg")
            ]

            if sensitiveUserDirs.contains(candidate) {
                throw SecuritySandboxError.pathViolation("Mounting protected user directory '\(candidate)' directly as container workspace is prohibited.")
            }

            let forbiddenRoots: Set<String> = [
                "/System",
                "/Library",
                "/usr",
                "/bin",
                "/sbin",
                "/etc",
                "/var",
                "/private",
                "/private/etc",
                "/private/var",
                "/dev",
                "/Volumes"
            ]

            if forbiddenRoots.contains(candidate) {
                throw SecuritySandboxError.pathViolation("Mounting system directory '\(candidate)' as container workspace is prohibited.")
            }

            let forbiddenPrefixes = [
                "/System/",
                "/Library/",
                "/usr/",
                "/bin/",
                "/sbin/",
                "/etc/",
                "/private/etc/",
                "/dev/",
                "/Volumes/"
            ]

            for prefix in forbiddenPrefixes {
                if candidate.hasPrefix(prefix) {
                    throw SecuritySandboxError.pathViolation("Mounting system directory '\(candidate)' as container workspace is prohibited.")
                }
            }

            // Reject /var and /private/var subpaths outside of the temporary directory (/var/folders/)
            if candidate.hasPrefix("/var/") || candidate.hasPrefix("/private/var/") {
                let isTempFolder = candidate.hasPrefix("/var/folders/") || candidate.hasPrefix("/private/var/folders/")
                if !isTempFolder {
                    throw SecuritySandboxError.pathViolation("Mounting system directory '\(candidate)' as container workspace is prohibited.")
                }
            }
        }

        // Subdirectories in system temp directories are explicitly allowed as test / container workspaces
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        if standardized != tempDir && (standardized.hasPrefix(tempDir + "/") || standardized.hasPrefix("/tmp/") || standardized.hasPrefix("/private/tmp/")) {
            return
        }
        if resolved != tempDir && (resolved.hasPrefix(tempDir + "/") || resolved.hasPrefix("/tmp/") || resolved.hasPrefix("/private/tmp/")) {
            return
        }
    }
}

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
