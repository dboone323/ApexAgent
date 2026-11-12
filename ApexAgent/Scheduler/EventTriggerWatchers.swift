import Foundation
import Network
import Darwin

/// Protocol for real event trigger watchers.
public protocol EventTriggerWatcher: Sendable {
    func start() async throws
    func stop() async
}

// MARK: - File Event Watcher
public final class FileEventWatcher: EventTriggerWatcher, @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (EventTriggerPayload) async -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.apexagent.FileEventWatcher", qos: .utility)

    public init(path: String, handler: @escaping @Sendable (EventTriggerPayload) async -> Void) {
        self.path = (path as NSString).expandingTildeInPath
        self.handler = handler
    }

    public func start() async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "FileEventWatcher", code: 404, userInfo: [NSLocalizedDescriptionKey: "Watched path '\(path)' does not exist."])
        }

        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else {
            throw NSError(domain: "FileEventWatcher", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Failed to open file descriptor for '\(path)' (errno: \(errno))"])
        }
        self.fileDescriptor = fd

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib],
            queue: queue
        )

        src.setEventHandler { [weak self, weak src] in
            guard let self = self, let src = src else { return }
            let data = src.data
            var events: [String] = []
            if data.contains(.write) { events.append("write") }
            if data.contains(.delete) { events.append("delete") }
            if data.contains(.rename) { events.append("rename") }
            if data.contains(.extend) { events.append("extend") }
            if data.contains(.attrib) { events.append("attrib") }

            let payload = EventTriggerPayload(
                triggerType: "file",
                identifier: self.path,
                firedAt: Date(),
                metadata: ["events": events.joined(separator: ",")]
            )
            Task {
                await self.handler(payload)
            }
        }

        src.setCancelHandler {
            Darwin.close(fd)
        }

        self.source = src
        src.resume()
        AppLog.info(.routine, "FileEventWatcher: Monitoring file changes on '\(path)'")
    }

    public func stop() async {
        if let src = source {
            src.cancel()
            source = nil
        }
    }
}

// MARK: - Webhook Event Watcher
public final class WebhookEventWatcher: EventTriggerWatcher, @unchecked Sendable {
    private let endpoint: String
    private let port: UInt16
    private let secretToken: String?
    private let handler: @Sendable (EventTriggerPayload) async -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.apexagent.WebhookEventWatcher")

    public init(
        endpoint: String,
        port: UInt16,
        secretToken: String? = nil,
        handler: @escaping @Sendable (EventTriggerPayload) async -> Void
    ) {
        self.endpoint = endpoint
        self.port = port
        self.secretToken = secretToken
        self.handler = handler
    }

    public func start() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "WebhookEventWatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let list = try NWListener(using: params, on: nwPort)

        list.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        list.stateUpdateHandler = { state in
            switch state {
            case .ready:
                AppLog.info(.routine, "WebhookEventWatcher: Listening on port \(nwPort)")
            case .failed(let error):
                AppLog.error(.routine, "WebhookEventWatcher: Listener error: \(error)")
            default:
                break
            }
        }

        list.start(queue: queue)
        self.listener = list
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var accumulated = buffer
            if let data = data { accumulated.append(data) }

            if let (head, body) = Self.splitHeadAndBody(accumulated) {
                let cl = Self.contentLength(head) ?? 0
                if body.count >= cl {
                    self.dispatchComplete(connection: connection, head: head, body: Data(body.prefix(cl)))
                    return
                }
            }

            if error == nil && !isComplete && accumulated.count < 1_000_000 {
                self.receiveRequest(connection, buffer: accumulated)
                return
            }

            connection.cancel()
        }
    }

    private func dispatchComplete(connection: NWConnection, head: Data, body: Data) {
        let requestStr = String(decoding: head, as: UTF8.self)
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendHTTPResponse(connection: connection, statusCode: 400, body: "{\"error\":\"bad_request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "POST" else {
            sendHTTPResponse(connection: connection, statusCode: 405, body: "{\"error\":\"Method Not Allowed\"}")
            return
        }

        // Verify secret token if required
        if let token = self.secretToken {
            let hasAuth = requestStr.contains("Bearer \(token)") || requestStr.contains("X-Webhook-Secret: \(token)")
            if !hasAuth {
                sendHTTPResponse(connection: connection, statusCode: 401, body: "{\"error\":\"Unauthorized\"}")
                return
            }
        }

        let payload = EventTriggerPayload(
            triggerType: "webhook",
            identifier: self.endpoint,
            firedAt: Date(),
            metadata: ["endpoint": self.endpoint, "port": "\(self.port)"],
            dataPayload: body.isEmpty ? nil : body
        )

        sendHTTPResponse(connection: connection, statusCode: 200, body: "{\"status\":\"received\",\"endpoint\":\"\(self.endpoint)\"}")

        Task {
            await self.handler(payload)
        }
    }

    private static func splitHeadAndBody(_ data: Data) -> (head: Data, body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.endIndex)
        return (head, body)
    }

    private static func contentLength(_ head: Data) -> Int? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func sendHTTPResponse(connection: NWConnection, statusCode: Int, body: String) {
        let resp = "HTTP/1.1 \(statusCode) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        if let data = resp.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed({ _ in
                connection.cancel()
            }))
        } else {
            connection.cancel()
        }
    }
}

// MARK: - LAN Peer Event Watcher
public final class LANPeerEventWatcher: EventTriggerWatcher, @unchecked Sendable {
    private let port: UInt16
    private let handler: @Sendable (EventTriggerPayload) async -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.apexagent.LANPeerEventWatcher")

    public init(port: UInt16, handler: @escaping @Sendable (EventTriggerPayload) async -> Void) {
        self.port = port
        self.handler = handler
    }

    public func start() async throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LANPeerEventWatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port \(port)"])
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let list = try NWListener(using: params, on: nwPort)

        list.newConnectionHandler = { [weak self] connection in
            self?.handlePeerConnection(connection)
        }

        list.start(queue: queue)
        self.listener = list
        AppLog.info(.routine, "LANPeerEventWatcher: Listening for LAN peer packets on port \(port)")
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
    }

    private func handlePeerConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self = self, let data = data, error == nil else {
                connection.cancel()
                return
            }

            let ack = "{\"status\":\"acknowledged\"}\n".data(using: .utf8)
            connection.send(content: ack, completion: .contentProcessed({ _ in
                connection.cancel()
            }))

            let peerEndpointStr = "\(connection.endpoint)"
            let payload = EventTriggerPayload(
                triggerType: "lanPeer",
                identifier: peerEndpointStr,
                firedAt: Date(),
                metadata: ["peer": peerEndpointStr, "bytes": "\(data.count)"],
                dataPayload: data
            )

            Task {
                await self.handler(payload)
            }
        }
    }
}

// MARK: - Mail Event Watcher
public final class MailEventWatcher: EventTriggerWatcher, @unchecked Sendable {
    private let pollIntervalSeconds: TimeInterval
    private let handler: @Sendable (EventTriggerPayload) async -> Void
    private var pollingTask: Task<Void, Never>?
    private var lastKnownCount: Int?

    public init(
        pollIntervalSeconds: TimeInterval = 2.0,
        handler: @escaping @Sendable (EventTriggerPayload) async -> Void
    ) {
        self.pollIntervalSeconds = pollIntervalSeconds
        self.handler = handler
    }

    public func start() async throws {
        // Query baseline count
        let initialCount = await queryMailInboxCount()
        self.lastKnownCount = initialCount

        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let nanos = UInt64(self.pollIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                guard !Task.isCancelled else { break }

                if let current = await self.queryMailInboxCount(), let baseline = self.lastKnownCount {
                    if current != baseline {
                        self.lastKnownCount = current
                        let details = await self.queryLatestMailDetails()
                        let payload = EventTriggerPayload(
                            triggerType: "mail",
                            identifier: "Mail.app/inbox",
                            firedAt: Date(),
                            metadata: [
                                "inboxCount": "\(current)",
                                "sender": details.sender,
                                "subject": details.subject
                            ]
                        )
                        await self.handler(payload)
                    }
                }
            }
        }
        AppLog.info(.routine, "MailEventWatcher: Started monitoring Mail.app inbox (baseline: \(initialCount ?? -1))")
    }

    public func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func queryMailInboxCount() async -> Int? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"Mail\" to get count of messages of inbox"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(returning: Int(str))
                } else {
                    continuation.resume(returning: nil)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    private func queryLatestMailDetails() async -> (sender: String, subject: String) {
        await withCheckedContinuation { continuation in
            let script = "tell application \"Mail\"\nif (count of messages of inbox) > 0 then\nset m to first message of inbox\nreturn (sender of m) & \"|||\" & (subject of m)\nend if\nreturn \"Unknown|||No Subject\"\nend tell"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let parts = str.components(separatedBy: "|||")
                let sender = parts.first ?? "Unknown"
                let subject = parts.count > 1 ? parts[1] : ""
                continuation.resume(returning: (sender, subject))
            } catch {
                continuation.resume(returning: ("Unknown", ""))
            }
        }
    }
}

// MARK: - Calendar Event Watcher
public final class CalendarEventWatcher: EventTriggerWatcher, @unchecked Sendable {
    private let horizonMinutes: Int
    private let handler: @Sendable (EventTriggerPayload) async -> Void
    private var pollingTask: Task<Void, Never>?
    private var knownEventIds: Set<String> = []

    public init(
        horizonMinutes: Int = 15,
        handler: @escaping @Sendable (EventTriggerPayload) async -> Void
    ) {
        self.horizonMinutes = horizonMinutes
        self.handler = handler
    }

    public func start() async throws {
        pollingTask = Task { [weak self] in
            guard let self = self else { return }
            while !Task.isCancelled {
                let events = await self.queryUpcomingCalendarEvents()
                for event in events {
                    if !self.knownEventIds.contains(event.id) {
                        self.knownEventIds.insert(event.id)
                        let payload = EventTriggerPayload(
                            triggerType: "calendar",
                            identifier: event.title,
                            firedAt: Date(),
                            metadata: [
                                "title": event.title,
                                "startDate": event.startDate
                            ]
                        )
                        await self.handler(payload)
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        AppLog.info(.routine, "CalendarEventWatcher: Started monitoring calendar events (horizon: \(horizonMinutes)m)")
    }

    public func stop() async {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func queryUpcomingCalendarEvents() async -> [(id: String, title: String, startDate: String)] {
        await withCheckedContinuation { continuation in
            let script = "tell application \"Calendar\"\ntry\nif not running then return \"\"\nset upcoming to {}\nset rightNow to current date\nset horizon to rightNow + (\(self.horizonMinutes) * minutes)\nrepeat with c in calendars\nset evs to (events of c whose start date ≥ rightNow and start date ≤ horizon)\nrepeat with e in evs\nset end of upcoming to (id of e) & \"|||\" & (summary of e) & \"|||\" & (start date of e as string)\nend repeat\nend repeat\nset text item delimiters to linefeed\nreturn upcoming as string\non error\nreturn \"\"\nend try\nend tell"

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let str = String(data: data, encoding: .utf8) ?? ""
                var results: [(id: String, title: String, startDate: String)] = []
                for line in str.components(separatedBy: .newlines) {
                    let parts = line.components(separatedBy: "|||")
                    if parts.count >= 2 {
                        results.append((id: parts[0], title: parts[1], startDate: parts.count > 2 ? parts[2] : ""))
                    }
                }
                continuation.resume(returning: results)
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}
