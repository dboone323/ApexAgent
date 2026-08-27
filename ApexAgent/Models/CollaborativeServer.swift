import Foundation
import Network
import AppKit

@MainActor
class CollaborativeServer: NSObject, ObservableObject {
    static let shared = CollaborativeServer()

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.apexagent.collab.server")

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 1337

    // Token Bucket Rate Limiter
    struct TokenBucket: Sendable {
        var tokens: Double
        var lastRefill: Date
    }
    nonisolated(unsafe) static var rateLimiters: [String: TokenBucket] = [:]
    private static let rateLimiterLock = NSLock()

    static func resetRateLimiter() {
        rateLimiterLock.lock()
        defer { rateLimiterLock.unlock() }
        rateLimiters.removeAll()
    }

    // RBAC Policy
    public struct PolicyRule: Codable, Sendable {
        public var endpoint: String
        public var requiredPermission: String
    }
    public struct Policy: Codable, Sendable {
        public var rules: [PolicyRule]
    }
    public var policy = Policy(rules: [
        PolicyRule(endpoint: "/api/state", requiredPermission: "read:state"),
        PolicyRule(endpoint: "/api/screen", requiredPermission: "read:screen"),
        PolicyRule(endpoint: "/", requiredPermission: "read:dashboard"),
        PolicyRule(endpoint: "/index.html", requiredPermission: "read:dashboard")
    ])

    override init() {
        super.init()
        let token = UserDefaults.standard.string(forKey: "apex.collabToken")
        if token == nil || token?.isEmpty == true {
            let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
            UserDefaults.standard.set(newToken, forKey: "apex.collabToken")
        }
    }

    /// Starts the server. `port: 0` asks the OS for an ephemeral port; the
    /// bound port is published via `self.port` once the listener reports ready.
    func start(port: UInt16 = 1337) {
        guard !isRunning else { return }
        self.port = port

        do {
            let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
            let bindHost = lanModeEnabled ? "0.0.0.0" : "127.0.0.1"

            let parameters = NWParameters.tcp
            if port != 0 {
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(bindHost), port: NWEndpoint.Port(rawValue: port)!)
            }
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        // Publish the OS-assigned port for ephemeral binds.
                        if let bound = listener.port?.rawValue, bound != 0 {
                            self.port = bound
                        }
                    case .failed(let error):
                        print("⚠️ Collaborative server failed: \(error)")
                        self.stop()
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                Task { @MainActor in
                    self.handleConnection(connection)
                }
            }

            listener.start(queue: queue)
        } catch {
            print("⚠️ Failed to start NWListener: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        print("🛑 Collaborative server stopped")
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection)
    }

    private func readRequest(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            Task { @MainActor in
                if let error = error {
                    print("Connection read error: \(error)")
                    connection.cancel()
                    return
                }

                guard let data = data, !data.isEmpty else {
                    connection.cancel()
                    return
                }

                if data.count > 1048576 {
                    self.sendHTTPResponse(html: "Payload Too Large", status: "413 Payload Too Large", contentType: "text/plain", connection: connection)
                    return
                }

                let requestStr = String(decoding: data, as: UTF8.self)
                self.processRequest(requestStr: requestStr, connection: connection)
            }
        }
    }

    private func processRequest(requestStr: String, connection: NWConnection) {
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            sendHTTPResponse(html: "Bad Request", status: "400 Bad Request", contentType: "text/plain", connection: connection)
            return
        }

        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendHTTPResponse(html: "Bad Request", status: "400 Bad Request", contentType: "text/plain", connection: connection)
            return
        }

        // Parse HTTP headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerParts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if headerParts.count == 2 {
                headers[headerParts[0].lowercased()] = headerParts[1]
            }
        }

        let clientIP = getClientIP(connection: connection)
        let path = parts[1]
        let plainPath = path.split(separator: "?").first.map(String.init) ?? path

        // 1. Rate Limiting Check
        if isRateLimited(clientIP: clientIP) {
            logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: false, decision: "Rate Limited (429)")
            sendHTTPResponse(html: "Too Many Requests", status: "429 Too Many Requests", contentType: "text/plain", connection: connection)
            return
        }

        // Security Controls: Prevent DNS Rebinding and Cross-Site Request Forgery (CSRF) for non-LAN
        let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
        if !lanModeEnabled {
            if let host = headers["host"] {
                let allowedHosts = ["localhost:\(port)", "127.0.0.1:\(port)", "localhost", "127.0.0.1"]
                let cleanHost = host.split(separator: "@").last.map(String.init) ?? host
                if !allowedHosts.contains(cleanHost) {
                    logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: false, decision: "Forbidden Host Header (403)")
                    sendHTTPResponse(html: "Forbidden: Unauthorized Host Header", status: "403 Forbidden", contentType: "text/plain", connection: connection)
                    return
                }
            }

            if let origin = headers["origin"] {
                let allowedOrigins = ["http://localhost:\(port)", "http://127.0.0.1:\(port)", "http://localhost", "http://127.0.0.1"]
                if !allowedOrigins.contains(origin) {
                    logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: false, decision: "Forbidden Origin (403)")
                    sendHTTPResponse(html: "Forbidden: Unauthorized Cross-Origin Request", status: "403 Forbidden", contentType: "text/plain", connection: connection)
                    return
                }
            }
        }

        // 2. Token Auth Extraction (from query params or header)
        var queryToken: String? = nil
        if let url = URL(string: "http://localhost" + path),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let tokenQuery = components.queryItems?.first(where: { $0.name == "token" }) {
            queryToken = tokenQuery.value
        }

        // 3. Authorization Check
        let authorized = isAuthorized(headers: headers, queryToken: queryToken, connection: connection)
        guard authorized else {
            logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: false, decision: "Unauthorized (401)")
            sendHTTPResponse(html: "Unauthorized: Invalid or missing token", status: "401 Unauthorized", contentType: "text/plain", connection: connection)
            return
        }

        // 4. RBAC Policy Check
        let rule = policy.rules.first(where: { $0.endpoint == plainPath })
        let requiredPermission = rule?.requiredPermission

        if let requiredPerm = requiredPermission {
            let requestToken = queryToken ?? headers["authorization"]?.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !hasPermission(token: requestToken, requiredPermission: requiredPerm) {
                logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: true, decision: "Forbidden (403): Missing permission \(requiredPerm)")
                sendHTTPResponse(html: "Forbidden: Missing required permission \(requiredPerm)", status: "403 Forbidden", contentType: "text/plain", connection: connection)
                return
            }
        }

        logAccess(clientIP: clientIP, endpoint: plainPath, isAuthorized: true, decision: "Allowed (200)")

        // Serve Endpoints
        if plainPath == "/" || plainPath == "/index.html" {
            // Serve Dashboard HTML
            let html = getDashboardHTML()
            sendHTTPResponse(html: html, status: "200 OK", contentType: "text/html", connection: connection)
        } else if plainPath == "/api/state" {
            // Serve JSON State
            Task { @MainActor in
                let json = await getJSONState()
                sendHTTPResponse(html: json, status: "200 OK", contentType: "application/json", connection: connection)
            }
        } else if plainPath.starts(with: "/api/screen") {
            // Serve Screen Capture
            Task { @MainActor in
                if let screenshot = ScreenStreamer.shared.getLatestFrame(),
                   let tiffData = screenshot.tiffRepresentation,
                   let bitmap = NSBitmapImageRep(data: tiffData),
                   let pngData = bitmap.representation(using: .png, properties: [:]) {
                    sendHTTPDataResponse(data: pngData, status: "200 OK", contentType: "image/png", connection: connection)
                } else {
                    sendHTTPResponse(html: "No screen capture available", status: "404 Not Found", contentType: "text/plain", connection: connection)
                }
            }
        } else {
            sendHTTPResponse(html: "Not Found", status: "404 Not Found", contentType: "text/plain", connection: connection)
        }
    }

    func getClientIP(connection: NWConnection) -> String {
        if case .hostPort(let host, _) = connection.endpoint {
            let hostStr = "\(host)"
            let cleanHost = hostStr.split(separator: "%").first.map(String.init) ?? hostStr
            return cleanHost
        }
        return "unknown"
    }

    func isRateLimited(clientIP: String) -> Bool {
        Self.rateLimiterLock.lock()
        defer { Self.rateLimiterLock.unlock() }

        let now = Date()
        let refillRate: Double = 10.0
        let capacity: Double = 20.0

        var bucket = Self.rateLimiters[clientIP] ?? TokenBucket(tokens: capacity, lastRefill: now)
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        bucket.tokens = min(capacity, bucket.tokens + elapsed * refillRate)
        bucket.lastRefill = now

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            Self.rateLimiters[clientIP] = bucket
            return false
        } else {
            Self.rateLimiters[clientIP] = bucket
            return true
        }
    }

    func isAuthorized(headers: [String: String], queryToken: String?, connection: NWConnection) -> Bool {
        let clientIP = getClientIP(connection: connection)

        // Only genuine loopback addresses are implicitly trusted. An
        // unresolvable client IP ("unknown") must NOT be trusted — it must
        // present a valid token (handled below in LAN mode).
        if clientIP == "127.0.0.1" || clientIP == "::1" || clientIP == "localhost" {
            return true
        }

        let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
        guard lanModeEnabled else {
            return false
        }

        let token = UserDefaults.standard.string(forKey: "apex.collabToken") ?? ""
        guard !token.isEmpty else {
            return false
        }

        if let authHeader = headers["authorization"],
           authHeader.lowercased().starts(with: "bearer ") {
            let requestToken = authHeader.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            return requestToken == token
        }

        if let qToken = queryToken {
            return qToken == token
        }

        return false
    }

    private func hasPermission(token: String, requiredPermission: String) -> Bool {
        let mainToken = UserDefaults.standard.string(forKey: "apex.collabToken") ?? ""
        if !mainToken.isEmpty && token == mainToken {
            return true
        }
        // Localhost/default bypass
        if token.isEmpty {
            return true
        }
        return false
    }

    func logAccess(clientIP: String, endpoint: String, isAuthorized: Bool, decision: String) {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let logsDir = homeDir.appendingPathComponent("Library/Logs/ApexAgent")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logFileURL = logsDir.appendingPathComponent("collab-access.log")

        let isoDate = ISO8601DateFormatter().string(from: Date())
        let logEntry: [String: Any] = [
            "timestamp": isoDate,
            "clientIP": clientIP,
            "endpoint": endpoint,
            "isAuthorized": isAuthorized,
            "decision": decision
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: logEntry),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        jsonString.append("\n")

        if let data = jsonString.data(using: .utf8) {
            if fm.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? fileHandle.close() }
                    _ = try? fileHandle.seekToEnd()
                    try? fileHandle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }

    private func sendHTTPResponse(html: String, status: String, contentType: String, connection: NWConnection) {
        guard let data = html.data(using: .utf8) else {
            connection.cancel()
            return
        }
        sendHTTPDataResponse(data: data, status: status, contentType: contentType, connection: connection)
    }

    private func sendHTTPDataResponse(data: Data, status: String, contentType: String, connection: NWConnection) {
        let headers = "HTTP/1.1 \(status)\r\n" +
                      "Content-Type: \(contentType)\r\n" +
                      "Content-Length: \(data.count)\r\n" +
                      "Connection: close\r\n" +
                      "X-Content-Type-Options: nosniff\r\n" +
                      "X-Frame-Options: DENY\r\n" +
                      "Content-Security-Policy: default-src 'self'; img-src 'self' data:; style-src 'unsafe-inline'\r\n" +
                      "Server: ApexAgent\r\n\r\n"

        guard var responseData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }
        responseData.append(data)

        connection.send(content: responseData, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { error in
            if let error = error {
                print("Send error: \(error)")
            }
            // Defer cancellation slightly to prevent connection reset on client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                connection.cancel()
            }
        })
    }

    // MARK: - Dashboard HTML Generation

    private func getDashboardHTML() -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>Apex Agent — Collaboration Hub</title>
            <style>
                :root {
                    --bg: #0d0e12;
                    --panel: #161821;
                    --text: #e2e4ed;
                    --text-secondary: #9aa0b4;
                    --border: #232635;
                    --primary: #9d7df9;
                    --primary-gradient: linear-gradient(135deg, #9d7df9, #4a77e5);
                    --success: #3cdc84;
                    --warning: #f1a93c;
                    --failed: #eb5757;
                }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body {
                    background-color: var(--bg);
                    color: var(--text);
                    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                    padding: 30px;
                    line-height: 1.5;
                }
                header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    margin-bottom: 30px;
                    border-bottom: 1px solid var(--border);
                    padding-bottom: 20px;
                }
                .logo-container {
                    display: flex;
                    align-items: center;
                    gap: 15px;
                }
                .logo-icon {
                    width: 44px;
                    height: 44px;
                    border-radius: 50%;
                    background: var(--primary-gradient);
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 20px;
                    box-shadow: 0 0 15px rgba(157, 125, 249, 0.4);
                }
                h1 {
                    font-size: 24px;
                    font-weight: 700;
                    letter-spacing: -0.5px;
                }
                .status-badge {
                    display: inline-flex;
                    align-items: center;
                    gap: 8px;
                    font-size: 13px;
                    font-weight: 600;
                    background: var(--panel);
                    padding: 8px 14px;
                    border-radius: 20px;
                    border: 1px solid var(--border);
                }
                .status-dot {
                    width: 8px;
                    height: 8px;
                    border-radius: 50%;
                    background-color: var(--text-secondary);
                }
                .status-dot.active {
                    background-color: var(--success);
                    box-shadow: 0 0 8px var(--success);
                    animation: pulse 2s infinite;
                }
                @keyframes pulse {
                    0% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(60, 220, 132, 0.7); }
                    70% { transform: scale(1); box-shadow: 0 0 0 6px rgba(60, 220, 132, 0); }
                    100% { transform: scale(0.95); box-shadow: 0 0 0 0 rgba(60, 220, 132, 0); }
                }
                .grid {
                    display: grid;
                    grid-template-columns: 1.5fr 1fr;
                    gap: 30px;
                }
                @media (max-width: 1024px) {
                    .grid { grid-template-columns: 1fr; }
                }
                .panel {
                    background-color: var(--panel);
                    border: 1px solid var(--border);
                    border-radius: 16px;
                    padding: 24px;
                    display: flex;
                    flex-direction: column;
                    gap: 20px;
                    box-shadow: 0 4px 24px rgba(0,0,0,0.25);
                }
                .panel-title {
                    font-size: 16px;
                    font-weight: 700;
                    color: var(--text-secondary);
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    border-bottom: 1px solid var(--border);
                    padding-bottom: 10px;
                }
                .message-list {
                    display: flex;
                    flex-direction: column;
                    gap: 16px;
                    max-height: 420px;
                    overflow-y: auto;
                    padding-right: 4px;
                }
                .message {
                    display: flex;
                    flex-direction: column;
                    gap: 6px;
                    padding: 12px 14px;
                    border-radius: 12px;
                    border: 1px solid var(--border);
                    background: rgba(255, 255, 255, 0.02);
                }
                .message-header {
                    display: flex;
                    justify-content: space-between;
                    font-size: 12px;
                    color: var(--text-secondary);
                }
                .message-body {
                    font-size: 14px;
                    color: var(--text);
                    word-wrap: break-word;
                }
                .pill {
                    display: inline-flex;
                    align-items: center;
                    gap: 6px;
                    padding: 6px 10px;
                    border-radius: 999px;
                    background: rgba(255, 255, 255, 0.05);
                    border: 1px solid var(--border);
                    font-size: 13px;
                    color: var(--text-secondary);
                }
                .pill.active {
                    border-color: var(--success);
                    color: var(--success);
                }
                .input-row {
                    display: flex;
                    gap: 10px;
                }
                .input {
                    flex: 1;
                    padding: 10px 12px;
                    border-radius: 10px;
                    border: 1px solid var(--border);
                    background: rgba(0, 0, 0, 0.25);
                    color: var(--text);
                    outline: none;
                }
                .button {
                    padding: 10px 14px;
                    border-radius: 10px;
                    border: 1px solid var(--border);
                    background: var(--primary-gradient);
                    color: white;
                    font-weight: 600;
                    cursor: pointer;
                    border: none;
                }
                footer {
                    margin-top: 24px;
                    font-size: 12px;
                    color: var(--text-secondary);
                }
            </style>
        </head>
        <body>
            <header>
                <div class="logo-container">
                    <div class="logo-icon">🧠</div>
                    <h1>Apex Agent</h1>
                </div>
                <div class="status-badge">
                    <span class="status-dot active"></span>
                    <span>Collaboration Hub</span>
                </div>
            </header>

            <div class="grid">
                <section class="panel">
                    <div class="panel-title">Conversation</div>
                    <div class="message-list" id="messageList">
                        <div class="message">
                            <div class="message-header">
                                <span>Assistant</span>
                                <span>Just now</span>
                            </div>
                            <div class="message-body">Collaboration hub is running.</div>
                        </div>
                    </div>
                    <div class="input-row">
                        <input class="input" id="messageInput" placeholder="Type a message..." />
                        <button class="button" id="sendButton">Send</button>
                    </div>
                </section>

                <section class="panel">
                    <div class="panel-title">Status</div>
                    <div style="display:flex; flex-direction:column; gap:12px;">
                        <div class="pill active">Server: running</div>
                        <div class="pill">Port: \(port)</div>
                        <div class="pill">Mode: \(UserDefaults.standard.bool(forKey: "apex.lanModeEnabled") ? "LAN" : "Localhost")</div>
                    </div>
                </section>
            </div>

            <footer>
                Apex Agent · On-device, privacy-first collaboration hub
            </footer>
        </body>
        </html>
        """
    }

    func getDashboardHTMLSnapshot() -> String {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let logsDir = homeDir.appendingPathComponent("Library/Logs/ApexAgent")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logFileURL = logsDir.appendingPathComponent("collab-access.log")

        let isoDate = ISO8601DateFormatter().string(from: Date())
        let logEntry: [String: Any] = [
            "timestamp": isoDate,
            "clientIP": "snapshot",
            "endpoint": "/",
            "isAuthorized": true,
            "decision": "Snapshot (200)"
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: logEntry),
              var jsonString = String(data: jsonData, encoding: .utf8) else {
            return getDashboardHTML()
        }
        jsonString.append("\n")

        if let data = jsonString.data(using: .utf8) {
            if fm.fileExists(atPath: logFileURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                    defer { try? fileHandle.close() }
                    _ = try? fileHandle.seekToEnd()
                    try? fileHandle.write(contentsOf: data)
                }
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }

        return getDashboardHTML()
    }

    // MARK: - Health

    func health() -> (running: Bool, port: UInt16, lanMode: Bool) {
        let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
        return (running: isRunning, port: port, lanMode: lanModeEnabled)
    }

    // MARK: - JSON State

    func getJSONState() async -> String {
        let health = self.health()
        let dict: [String: Any] = [
            "running": health.running,
            "port": health.port,
            "lanMode": health.lanMode,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}
