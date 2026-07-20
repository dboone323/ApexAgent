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
    private struct TokenBucket {
        var tokens: Double
        var lastRefill: Date
    }
    private var rateLimiters: [String: TokenBucket] = [:]
    private let rateLimiterLock = NSLock()

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

    func start(port: UInt16 = 1337) {
        guard !isRunning else { return }
        self.port = port

        do {
            let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
            let bindHost = lanModeEnabled ? "0.0.0.0" : "127.0.0.1"

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(bindHost), port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
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
        self.isRunning = false
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
        rateLimiterLock.lock()
        defer { rateLimiterLock.unlock() }

        let now = Date()
        let refillRate: Double = 10.0
        let capacity: Double = 20.0

        var bucket = rateLimiters[clientIP] ?? TokenBucket(tokens: capacity, lastRefill: now)
        let elapsed = now.timeIntervalSince(bucket.lastRefill)
        bucket.tokens = min(capacity, bucket.tokens + elapsed * refillRate)
        bucket.lastRefill = now

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            rateLimiters[clientIP] = bucket
            return false
        } else {
            rateLimiters[clientIP] = bucket
            return true
        }
    }

    func isAuthorized(headers: [String: String], queryToken: String?, connection: NWConnection) -> Bool {
        let lanModeEnabled = UserDefaults.standard.bool(forKey: "apex.lanModeEnabled")
        let clientIP = getClientIP(connection: connection)

        if clientIP == "127.0.0.1" || clientIP == "::1" || clientIP == "localhost" || clientIP == "unknown" {
            return true
        }

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

    private func logAccess(clientIP: String, endpoint: String, isAuthorized: Bool, decision: String) {
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
                      "Connection: close\r\n\r\n"

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
                    max-height: 500px;
                    overflow-y: auto;
                    padding-right: 5px;
                }
                .message {
                    padding: 16px;
                    border-radius: 12px;
                    font-size: 14px;
                    max-width: 85%;
                }
                .message.user {
                    background-color: var(--border);
                    align-self: flex-end;
                    border-bottom-right-radius: 2px;
                }
                .message.assistant {
                    background-color: #1e2230;
                    align-self: flex-start;
                    border-bottom-left-radius: 2px;
                    border-left: 3px solid var(--primary);
                }
                .plan-list {
                    display: flex;
                    flex-direction: column;
                    gap: 12px;
                }
                .plan-step {
                    display: flex;
                    align-items: center;
                    gap: 12px;
                    padding: 12px;
                    background-color: var(--bg);
                    border-radius: 8px;
                    border: 1px solid var(--border);
                    font-size: 13.5px;
                }
                .step-status {
                    width: 18px;
                    height: 18px;
                    border-radius: 50%;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    font-size: 11px;
                }
                .step-status.completed { background: rgba(60,220,132,0.15); color: var(--success); }
                .step-status.running { background: rgba(241,169,60,0.15); color: var(--warning); animation: spin 1.5s linear infinite; }
                .step-status.failed { background: rgba(235,87,87,0.15); color: var(--failed); }
                .step-status.queued { background: rgba(154,160,180,0.1); color: var(--text-secondary); }

                @keyframes spin { 100% { transform: rotate(360deg); } }

                .screen-container {
                    width: 100%;
                    border-radius: 12px;
                    overflow: hidden;
                    border: 1px solid var(--border);
                    background: var(--bg);
                    position: relative;
                }
                .screen-container img {
                    width: 100%;
                    height: auto;
                    display: block;
                }
                .placeholder-text {
                    padding: 40px;
                    text-align: center;
                    color: var(--text-secondary);
                    font-size: 14px;
                }
                .diagnostics-list, .tools-list, .projects-list {
                    display: flex;
                    flex-direction: column;
                    gap: 10px;
                }
                .diagnostic-card, .tool-card, .project-card {
                    background-color: var(--bg);
                    border: 1px solid var(--border);
                    border-radius: 8px;
                    padding: 12px;
                    font-size: 13px;
                }
                .card-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    font-weight: 600;
                    margin-bottom: 6px;
                }
                .badge {
                    padding: 2px 8px;
                    border-radius: 12px;
                    font-size: 10px;
                    font-weight: 700;
                    text-transform: uppercase;
                }
                .badge.pass { background-color: rgba(60,220,132,0.15); color: var(--success); }
                .badge.warning { background-color: rgba(241,169,60,0.15); color: var(--warning); }
                .badge.fail { background-color: rgba(235,87,87,0.15); color: var(--failed); }

                ::-webkit-scrollbar { width: 6px; }
                ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
            </style>
        </head>
        <body>
            <header>
                <div class="logo-container">
                    <div class="logo-icon">⚡</div>
                    <div>
                        <h1 id="conv-title">Apex Agent Collaboration Hub</h1>
                        <p style="font-size: 12px; color: var(--text-secondary)">Live-sharing workspace activity</p>
                    </div>
                </div>
                <div class="status-badge">
                    <div class="status-dot" id="live-dot"></div>
                    <span id="live-status">Offline</span>
                </div>
            </header>

            <div class="grid">
                <div class="panel">
                    <div class="panel-title">Active Conversation Log</div>
                    <div class="message-list" id="chat-logs">
                        <div class="placeholder-text">Waiting for conversation to start...</div>
                    </div>
                </div>

                <div style="display: flex; flex-direction: column; gap: 30px;">
                    <div class="panel">
                        <div class="panel-title">Current Execution Plan</div>
                        <div class="plan-list" id="plan-steps">
                            <div class="placeholder-text">No active execution plans.</div>
                        </div>
                    </div>

                    <div class="panel">
                        <div class="panel-title">Agent Vision Live View</div>
                        <div class="screen-container">
                            <img src="/api/screen" id="screen-img" onerror="this.style.display='none'; document.getElementById('screen-placeholder').style.display='block';">
                            <div class="placeholder-text" id="screen-placeholder" style="display:none;">Waiting for screen frames...</div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="grid" style="margin-top: 30px;">
                <div class="panel">
                    <div class="panel-title" style="margin-bottom: 10px;">Workspace Health & System Diagnostics</div>
                    <div class="diagnostics-list" id="diag-list">
                        <div class="placeholder-text">Loading diagnostics...</div>
                    </div>
                    <div class="panel-title" style="margin-top: 20px; margin-bottom: 10px;">Loaded Custom Tools (~/.apex/tools)</div>
                    <div class="tools-list" id="tools-list">
                        <div class="placeholder-text">Loading tools...</div>
                    </div>
                </div>

                <div class="panel">
                    <div class="panel-title" style="margin-bottom: 10px;">Swift/Xcode App Workspace Health</div>
                    <div class="projects-list" id="projects-list">
                        <div class="placeholder-text">No projects audited. Ask Apex: "Audit the 5 swift apps".</div>
                    </div>
                </div>
            </div>

            <script>
                async function updateState() {
                    try {
                        const response = await fetch('/api/state');
                        if (!response.ok) throw new Error('Response error');
                        const data = await response.json();

                        // Update title
                        document.getElementById('conv-title').innerText = data.title || 'New Conversation';

                        // Update status badge
                        const dot = document.getElementById('live-dot');
                        const label = document.getElementById('live-status');
                        if (data.isGenerating) {
                            dot.className = 'status-dot active';
                            label.innerText = 'Agent Active';
                        } else {
                            dot.className = 'status-dot';
                            label.innerText = 'Agent Idle';
                        }

                        // Update Messages
                        const chatLogs = document.getElementById('chat-logs');
                        if (data.messages && data.messages.length > 0) {
                            chatLogs.innerHTML = '';
                            data.messages.forEach(msg => {
                                const div = document.createElement('div');
                                div.className = 'message ' + msg.role;
                                div.innerText = msg.content;
                                chatLogs.appendChild(div);
                            });
                        } else {
                            chatLogs.innerHTML = '<div class="placeholder-text">Waiting for conversation to start...</div>';
                        }

                        // Update Plan
                        const planSteps = document.getElementById('plan-steps');
                        if (data.plan && data.plan.length > 0) {
                            planSteps.innerHTML = '';
                            data.plan.forEach(step => {
                                const div = document.createElement('div');
                                div.className = 'plan-step';

                                const icon = document.createElement('div');
                                icon.className = 'step-status ' + step.status;
                                if (step.status === 'completed') icon.innerText = '✓';
                                else if (step.status === 'running') icon.innerText = '⟳';
                                else if (step.status === 'failed') icon.innerText = '✗';
                                else icon.innerText = '•';

                                const title = document.createElement('span');
                                title.innerText = step.title;

                                div.appendChild(icon);
                                div.appendChild(title);
                                planSteps.appendChild(div);
                            });
                        } else {
                            planSteps.innerHTML = '<div class="placeholder-text">No active execution plans.</div>';
                        }

                        // Update Diagnostics
                        const diagList = document.getElementById('diag-list');
                        if (data.diagnostics && data.diagnostics.length > 0) {
                            diagList.innerHTML = '';
                            data.diagnostics.forEach(item => {
                                const card = document.createElement('div');
                                card.className = 'diagnostic-card';
                                const statusClass = item.status.toLowerCase();
                                card.innerHTML = `
                                    <div class="card-header">
                                        <span>${item.name}</span>
                                        <span class="badge ${statusClass}">${item.status}</span>
                                    </div>
                                    <div style="color: var(--text-secondary); font-size: 11px;">${item.message}</div>
                                `;
                                diagList.appendChild(card);
                            });
                        }

                        // Update Custom Tools
                        const toolsList = document.getElementById('tools-list');
                        if (data.dynamicTools && data.dynamicTools.length > 0) {
                            toolsList.innerHTML = '';
                            data.dynamicTools.forEach(tool => {
                                const card = document.createElement('div');
                                card.className = 'tool-card';
                                card.innerHTML = `
                                    <div class="card-header">
                                        <span>⚙️ ${tool.name}</span>
                                    </div>
                                    <div style="color: var(--text-secondary); font-size: 11px; margin-bottom: 4px;">${tool.description}</div>
                                    <div style="font-family: monospace; font-size: 9px; color: var(--primary); word-break: break-all;">${tool.scriptPath}</div>
                                `;
                                toolsList.appendChild(card);
                            });
                        } else {
                            toolsList.innerHTML = '<div class="placeholder-text">No custom dynamic tools loaded.</div>';
                        }

                        // Update Projects
                        const projList = document.getElementById('projects-list');
                        if (data.projects && data.projects.length > 0) {
                            projList.innerHTML = '';
                            data.projects.forEach(proj => {
                                const card = document.createElement('div');
                                card.className = 'project-card';
                                const hasWarnings = proj.warnings && proj.warnings.length > 0;
                                const hasBroken = proj.brokenReferences && proj.brokenReferences.length > 0;
                                const statusClass = hasBroken ? 'fail' : (hasWarnings ? 'warning' : 'pass');
                                const statusText = hasBroken ? 'Critical' : (hasWarnings ? 'Warning' : 'Healthy');

                                var warningsHtml = '';
                                if (hasWarnings) {
                                    warningsHtml = '<div style="margin-top: 6px; font-size: 11px; color: var(--warning);"><strong>Compliance Findings:</strong>';
                                    proj.warnings.forEach(w => {
                                        warningsHtml += `<div style="padding-left: 6px;">• ${w}</div>`;
                                    });
                                    warningsHtml += '</div>';
                                }

                                card.innerHTML = `
                                    <div class="card-header">
                                        <span>📦 ${proj.name}</span>
                                        <span class="badge ${statusClass}">${statusText}</span>
                                    </div>
                                    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 4px; font-size: 11.5px; color: var(--text-secondary); margin-bottom: 4px;">
                                        <div>Swift: <strong>${proj.swiftVersion}</strong></div>
                                        <div>Concurrency: <strong>${proj.strictConcurrency}</strong></div>
                                        <div>SDK Target: <strong>${proj.deploymentTarget}</strong></div>
                                        <div>Swift Files: <strong>${proj.fileCount}</strong></div>
                                        <div>TODOs/FIXMEs: <strong>${proj.todoCount}</strong></div>
                                    </div>
                                    ${warningsHtml}
                                `;
                                projList.appendChild(card);
                            });
                        } else {
                            projList.innerHTML = '<div class="placeholder-text">No Xcode projects audited yet. Ask Apex: "Audit my swift apps".</div>';
                        }

                        // Reload screen
                        const screenImg = document.getElementById('screen-img');
                        screenImg.src = '/api/screen?t=' + Date.now();
                        screenImg.style.display = 'block';
                        document.getElementById('screen-placeholder').style.display = 'none';

                    } catch (err) {
                        console.error('Failed to sync server state', err);
                        document.getElementById('live-dot').className = 'status-dot';
                        document.getElementById('live-status').innerText = 'Offline';
                    }
                }

                setInterval(updateState, 2000);
                updateState();
            </script>
        </body>
        </html>
        """
    }

    // MARK: - JSON State Fetch

    private func getJSONState() async -> String {
        let orchestrator = MCPManager.shared.orchestrator

        let messages = orchestrator.messages.map { msg -> [String: Any] in
            let roleStr = switch msg.role {
            case .user: "user"
            case .assistant: "assistant"
            case .system: "system"
            }
            return [
                "role": roleStr,
                "content": msg.content
            ]
        }

        let plan = orchestrator.activePlan.map { step -> [String: Any] in
            return [
                "title": step.title,
                "status": step.status.rawValue
            ]
        }

        let diagnostics = await DiagnosticManager.runSelfCheck().map { item -> [String: Any] in
            return [
                "name": item.name,
                "category": item.category,
                "status": item.status.rawValue,
                "message": item.message
            ]
        }

        let projects = ProjectAuditor.shared.getCachedReports().map { report -> [String: Any] in
            return [
                "name": report.name,
                "path": report.path,
                "swiftVersion": report.swiftVersion,
                "strictConcurrency": report.strictConcurrency,
                "deploymentTarget": report.deploymentTarget,
                "fileCount": report.fileCount,
                "todoCount": report.todoCount,
                "brokenReferences": report.brokenReferences,
                "warnings": report.warnings
            ]
        }

        let dynamicTools = DynamicToolbox.shared.dynamicTools.map { (name, entry) -> [String: Any] in
            return [
                "name": name,
                "description": entry.description,
                "scriptPath": entry.scriptPath ?? ""
            ]
        }

        let stateDict: [String: Any] = [
            "title": orchestrator.currentConversationTitle,
            "isGenerating": orchestrator.isGenerating,
            "messages": messages,
            "plan": plan,
            "diagnostics": diagnostics,
            "projects": projects,
            "dynamicTools": dynamicTools
        ]

        if let data = try? JSONSerialization.data(withJSONObject: stateDict, options: .prettyPrinted),
           let str = String(data: data, encoding: .utf8) {
            return str
        }

        return "{}"
    }
}
