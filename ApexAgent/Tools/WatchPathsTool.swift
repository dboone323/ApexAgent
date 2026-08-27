import Foundation
import FoundationModels

private final class WatcherRegistry: @unchecked Sendable {
    static let shared = WatcherRegistry()
    private let lock = NSLock()
    
    struct PathWatcher {
        let source: DispatchSourceFileSystemObject
        let path: String
        var changes: [String]
        let startedAt: Date
        var lastAccessedAt: Date
    }
    
    private var watchers: [String: PathWatcher] = [:]
    
    func start(path: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
        if watchers.count >= 5 {
            throw NSError(domain: "WatchPathsTool", code: 429, userInfo: [NSLocalizedDescriptionKey: "Maximum of 5 concurrent watchers allowed"])
        }
        
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else {
            throw NSError(domain: "WatchPathsTool", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open path: \(String(cString: strerror(errno)))"])
        }
        
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename, .extend], queue: .global())
        let watchId = "watch_\(UUID().uuidString.prefix(8))"
        
        watchers[watchId] = PathWatcher(source: source, path: path, changes: [], startedAt: Date(), lastAccessedAt: Date())
        
        source.setEventHandler { [weak self] in
            let data = source.data
            var events: [String] = []
            if data.contains(.write) { events.append("write") }
            if data.contains(.delete) { events.append("delete") }
            if data.contains(.rename) { events.append("rename") }
            if data.contains(.extend) { events.append("extend") }
            
            self?.recordEvents(watchId: watchId, events: events)
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        return watchId
    }
    
    private func recordEvents(watchId: String, events: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if var watcher = watchers[watchId] {
            watcher.changes.append(contentsOf: events)
            watchers[watchId] = watcher
        }
    }
    
    func check(watchId: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        cleanupLocked()
        guard var watcher = watchers[watchId] else {
            throw NSError(domain: "WatchPathsTool", code: 404, userInfo: [NSLocalizedDescriptionKey: "Watch ID not found"])
        }
        let changes = watcher.changes
        watcher.changes = []
        watcher.lastAccessedAt = Date()
        watchers[watchId] = watcher
        return changes
    }
    
    func stop(watchId: String) {
        lock.lock()
        defer { lock.unlock() }
        if let watcher = watchers.removeValue(forKey: watchId) {
            watcher.source.cancel()
        }
    }
    
    private func cleanupLocked() {
        let now = Date()
        for (id, watcher) in watchers {
            if now.timeIntervalSince(watcher.lastAccessedAt) > 1800 {
                watcher.source.cancel()
                watchers.removeValue(forKey: id)
            }
        }
    }
}

struct WatchPathsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "watch_paths"
    let description = "Watches directories for filesystem changes."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'start', 'check', or 'stop'")
        var action: String
        
        @Guide(description: "Path to watch (required for 'start')")
        var path: String?
        
        @Guide(description: "Watch ID returned by 'start' (required for 'check' and 'stop')")
        var watchId: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: nil) {
            switch arguments.action {
            case "start":
                guard let path = arguments.path else { return "ERROR: path is required for start" }
                let id = try WatcherRegistry.shared.start(path: path)
                return "Started watching path. Watch ID: \(id)"
            case "check":
                guard let watchId = arguments.watchId else { return "ERROR: watchId is required for check" }
                let changes = try WatcherRegistry.shared.check(watchId: watchId)
                if changes.isEmpty {
                    return "No changes detected."
                }
                return "Changes detected: \(changes.joined(separator: ", "))"
            case "stop":
                guard let watchId = arguments.watchId else { return "ERROR: watchId is required for stop" }
                WatcherRegistry.shared.stop(watchId: watchId)
                return "Stopped watching \(watchId)"
            default:
                return "ERROR: Invalid action '\(arguments.action)'. Must be start, check, or stop."
            }
        }
    }
}
