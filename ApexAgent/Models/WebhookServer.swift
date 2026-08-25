import Foundation
import Network

// MARK: - WebhookServer: localhost socket front for WebhookRouter (O5)
//
// Translates raw TCP bytes into `WebhookDelivery`, delegates every decision to
// the pure `WebhookRouter`, and writes the status back as JSON. Binds
// localhost only (capability URLs are local-first; expose via a relay or
// Tailscale Funnel if you need public delivery, mirroring OpenMausBot's
// guidance). HTTP handling is deliberately minimal: request line + headers,
// read exactly Content-Length body bytes, answer once, close.

final class WebhookServer: @unchecked Sendable {

    enum ServerError: Error {
        case invalidPort
        case startFailed(String)
    }

    /// Thread-safe slot for values produced on the listener queue.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ newValue: T) {
            lock.lock(); defer { lock.unlock() }
            value = newValue
        }
        func get() -> T? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private let manager: WebhookManager
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "apex.webhook.server")
    private(set) var port: UInt16 = 0
    /// Set when the app wants webhook deliveries to fire routines; when nil,
    /// accepted deliveries still return 202 but nothing is dispatched.
    var onAccepted: ((_ routineName: String, _ payload: WebhookPayload, _ eventName: String?, _ deliveryId: String?) -> Void)?

    init(manager: WebhookManager) {
        self.manager = manager
    }

    // MARK: Lifecycle

    /// Starts listening. Pass 0 for an OS-assigned port (tests).
    func start(preferredPort: UInt16 = 8800) throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let nwPort: NWEndpoint.Port
        if preferredPort == 0 {
            nwPort = .any
        } else if let p = NWEndpoint.Port(rawValue: preferredPort) {
            nwPort = p
        } else {
            throw ServerError.invalidPort
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw ServerError.startFailed(error.localizedDescription)
        }

        let ready = DispatchSemaphore(value: 0)
        let startError = Box<String>()

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startError.set(error.localizedDescription)
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        self.listener = listener
        listener.start(queue: queue)

        // Wait briefly for .ready so `port` is known to the caller.
        _ = ready.wait(timeout: .now() + 5)
        if let errorText = startError.get() {
            stop()
            throw ServerError.startFailed(errorText)
        }
        if port == 0 && preferredPort != 0 {
            stop()
            throw ServerError.startFailed("Listener did not become ready")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, buffer: Data())
    }

    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if let (head, body) = Self.splitHeadAndBody(accumulated),
               let contentLength = Self.contentLength(head),
               body.count >= contentLength {
                self.handleComplete(connection, head: head, body: Data(body.prefix(contentLength)))
                return
            }
            if error == nil && !isComplete && accumulated.count < 2 * WebhookManager.maxBodyBytes {
                self.receiveRequest(connection, buffer: accumulated)
                return
            }
            // Client hung up early or body never completed.
            self.respond(connection, status: 400, message: "Could not read webhook request")
            connection.cancel()
        }
    }

    private func handleComplete(_ connection: NWConnection, head: Data, body: Data) {
        let requestText = String(decoding: head, as: UTF8.self)
        var lines = requestText.components(separatedBy: "\r\n")
        let requestLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.count > 1 ? String(parts[1]) : "/"

        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let name = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        // Routing is by path only; strip any query string.
        let path = rawPath.split(separator: "?").first.map(String.init) ?? rawPath

        let delivery = WebhookDelivery(
            method: method,
            path: path,
            authorizationHeader: headers["authorization"],
            secretHeader: headers["x-apex-secret"],
            contentType: headers["content-type"],
            rawBody: String(decoding: body, as: UTF8.self),
            bodySize: body.count,
            eventName: headers["x-github-event"] ?? headers["x-webhook-event"] ?? headers["x-event-type"],
            deliveryId: headers["idempotency-key"] ?? headers["x-webhook-id"] ?? headers["x-github-delivery"])

        let outcome = WebhookRouter.route(manager: manager, request: delivery) { [weak self] endpoint, payload, eventName, deliveryId in
            guard let self, let onAccepted = self.onAccepted else { return }
            onAccepted(endpoint.targetRoutineName, payload, eventName, deliveryId)
        }

        var json = "{\"accepted\":false,\"error\":\"rejected\"}"
        if case .accepted(let routineName, let deliveryId, let duplicate) = outcome {
            json = "{\"accepted\":true,\"routine\":\"\(Self.escaped(routineName))\",\"duplicate\":\(duplicate)}"
            if let deliveryId { json += ",\"deliveryId\":\"\(Self.escaped(deliveryId))\"" }
        } else if case .rejected(_, let reason) = outcome {
            json = "{\"accepted\":false,\"error\":\"\(Self.escaped(reason))\"}"
        }

        respond(connection, status: outcome.statusCode, message: json)
    }

    private func respond(_ connection: NWConnection, status: Int, message: String) {
        let response = "HTTP/1.1 \(status) \(Self.reasonPhrase(for: status))\r\n" +
            "Content-Type: application/json\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            "Content-Length: \(message.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" + message
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Parsing helpers

    /// Split raw bytes into head (through \r\n\r\n) and body.
    static func splitHeadAndBody(_ data: Data) -> (head: Data, body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        let head = data.subdata(in: data.startIndex..<range.lowerBound)
        let body = data.subdata(in: range.upperBound..<data.endIndex)
        return (head, body)
    }

    static func contentLength(_ head: Data) -> Int? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            let lowered = line.lowercased()
            if lowered.hasPrefix("content-length:") {
                return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return 0  // no body expected
    }

    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Internal Server Error"
        }
    }

    static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}