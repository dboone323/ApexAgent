import Foundation

public struct FSEvent: Sendable, Codable {
    public let path: String
    public let flags: UInt

    public init(path: String, flags: UInt) {
        self.path = path
        self.flags = flags
    }
}

public actor FSEventsWatcher {
    private var activeSources: [String: any DispatchSourceFileSystemObject] = [:]
    
    public init() {}

    public func watch(
        path: String,
        onChange: @escaping @Sendable ([FSEvent]) -> Void
    ) async {
        let url = URL(fileURLWithPath: path)
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global()
        )

        source.setEventHandler { [weak source] in
            guard let source else { return }
            let event = FSEvent(path: path, flags: source.data.rawValue)
            onChange([event])
        }

        source.setCancelHandler {
            close(fileDescriptor)
        }

        source.resume()
        activeSources[path] = source
    }
    
    public func stopWatching(path: String) {
        activeSources[path]?.cancel()
        activeSources.removeValue(forKey: path)
    }
}
