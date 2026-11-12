import Foundation

/// Coordinator actor managing event triggers across file, webhook, LAN-peer, mail, and calendar sources.
public actor EventTriggerCoordinator {
    public static let shared = EventTriggerCoordinator()

    public typealias TriggerHandler = @Sendable (EventTriggerPayload) async -> Void

    private var configs: [UUID: EventTriggerConfig] = [:]
    private var handlers: [UUID: TriggerHandler] = [:]
    private var watchers: [UUID: any EventTriggerWatcher] = [:]
    private var statsMap: [UUID: TriggerStats] = [:]
    public private(set) var recentEvents: [EventTriggerPayload] = []

    public init() {}

    /// Registers a new event trigger configuration.
    @discardableResult
    public func register(
        id: UUID = UUID(),
        config: EventTriggerConfig,
        handler: @escaping TriggerHandler
    ) throws -> UUID {
        configs[id] = config
        handlers[id] = handler
        statsMap[id] = TriggerStats(kind: config.kind, identifier: config.identifier)
        AppLog.info(.routine, "EventTriggerCoordinator: Registered \(config.kind.rawValue) trigger [\(id)] for '\(config.identifier)'")
        return id
    }

    /// Unregisters an event trigger and halts its watcher.
    public func unregister(id: UUID) async {
        if let watcher = watchers.removeValue(forKey: id) {
            await watcher.stop()
        }
        configs.removeValue(forKey: id)
        handlers.removeValue(forKey: id)
        statsMap.removeValue(forKey: id)
        AppLog.info(.routine, "EventTriggerCoordinator: Unregistered trigger [\(id)]")
    }

    /// Starts a specific registered trigger.
    public func start(id: UUID) async throws {
        guard let config = configs[id], let handler = handlers[id] else {
            throw NSError(domain: "EventTriggerCoordinator", code: 404, userInfo: [NSLocalizedDescriptionKey: "Trigger [\(id)] not registered."])
        }

        // Stop existing watcher if already active
        if let existing = watchers[id] {
            await existing.stop()
            watchers.removeValue(forKey: id)
        }

        let watcher: any EventTriggerWatcher

        switch config.kind {
        case .file:
            guard let target = config.targetPath else {
                throw NSError(domain: "EventTriggerCoordinator", code: 400, userInfo: [NSLocalizedDescriptionKey: "File trigger requires targetPath"])
            }
            watcher = FileEventWatcher(path: target) { [weak self] payload in
                await self?.recordEvent(for: id, payload: payload)
                await handler(payload)
            }

        case .webhook:
            let port = config.port ?? 1338
            watcher = WebhookEventWatcher(endpoint: config.identifier, port: port, secretToken: config.secretToken) { [weak self] payload in
                await self?.recordEvent(for: id, payload: payload)
                await handler(payload)
            }

        case .lanPeer:
            let port = config.port ?? 1339
            watcher = LANPeerEventWatcher(port: port) { [weak self] payload in
                await self?.recordEvent(for: id, payload: payload)
                await handler(payload)
            }

        case .mail:
            watcher = MailEventWatcher(pollIntervalSeconds: config.pollIntervalSeconds) { [weak self] payload in
                await self?.recordEvent(for: id, payload: payload)
                await handler(payload)
            }

        case .calendar:
            watcher = CalendarEventWatcher(horizonMinutes: 15) { [weak self] payload in
                await self?.recordEvent(for: id, payload: payload)
                await handler(payload)
            }
        }

        try await watcher.start()
        watchers[id] = watcher
        AppLog.info(.routine, "EventTriggerCoordinator: Started watcher for \(config.kind.rawValue) trigger [\(id)]")
    }

    /// Stops a specific trigger.
    public func stop(id: UUID) async {
        if let watcher = watchers.removeValue(forKey: id) {
            await watcher.stop()
            AppLog.info(.routine, "EventTriggerCoordinator: Stopped watcher for trigger [\(id)]")
        }
    }

    /// Starts all registered triggers.
    public func startAll() async throws {
        for id in configs.keys {
            try await start(id: id)
        }
    }

    /// Stops all active watchers.
    public func stopAll() async {
        for watcher in watchers.values {
            await watcher.stop()
        }
        watchers.removeAll()
    }

    /// Returns statistics for all registered triggers.
    public func allStats() -> [TriggerStats] {
        Array(statsMap.values).sorted { $0.identifier < $1.identifier }
    }

    /// Returns statistics for a specific trigger.
    public func stats(for id: UUID) -> TriggerStats? {
        statsMap[id]
    }

    private func recordEvent(for id: UUID, payload: EventTriggerPayload) {
        recentEvents.insert(payload, at: 0)
        if recentEvents.count > 100 {
            recentEvents.removeLast(recentEvents.count - 100)
        }

        if var stats = statsMap[id] {
            stats.fireCount += 1
            stats.lastFiredAt = payload.firedAt
            stats.isLiveVerified = true
            statsMap[id] = stats
        }
        AppLog.info(.routine, "EventTriggerCoordinator: Event received \(payload.summary)")
    }
}
