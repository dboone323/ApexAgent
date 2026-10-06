import Foundation
import AppKit
import Network

@MainActor
public final class ApexGatewayServer {
    private let port: UInt16
    private let orchestrator: AgentOrchestrator
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    /// Connections that have presented the pre-shared token (C2).
    private var authenticatedConnections: Set<UUID> = []
    /// Max inbound frame body — caps the unbounded UInt32 length prefix (C2 DoS).
    nonisolated private static let maxFrameBytes: UInt32 = 8 * 1024 * 1024
    /// Keychain account for the pre-shared gateway token (C2).
    nonisolated static let gatewayTokenKeychainKey = "apex.gatewayToken"
    
    private let authenticationToken: String
    private var lastTerminalMessageId: UUID?
    
    public convenience init(port: UInt16 = 1337, orchestrator: AgentOrchestrator) {
        self.init(port: port, orchestrator: orchestrator, authenticationToken: Self.gatewayToken())
    }

    init(port: UInt16, orchestrator: AgentOrchestrator, authenticationToken: String) {
        self.port = port
        self.orchestrator = orchestrator
        self.authenticationToken = authenticationToken
        
        // Wire the orchestrator state change callback
        orchestrator.onStateChanged = { [weak self] in
            self?.broadcastState()
        }
        
        // Wire orchestrator confirmation interceptor
        orchestrator.confirmationGateway = { [weak self] toolName, arguments, riskDescription in
            await self?.requestRemoteConfirmation(toolName: toolName, arguments: arguments, riskDescription: riskDescription) ?? false
        }
    }

    /// The pre-shared token a client must present (via `.authenticate`) before
    /// the server honors any of its actions. Generated once and stored in the
    /// Keychain; on first generation it is printed so the user can see it.
    /// Local clients (e.g. ApexGatewayClient) read it from the same Keychain.
    static func gatewayToken() -> String {
        if let existing = KeychainManager.get(key: gatewayTokenKeychainKey), !existing.isEmpty {
            return existing
        }
        let fresh = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        if KeychainManager.save(key: gatewayTokenKeychainKey, value: fresh) {
            print("📡 [ApexGatewayServer] First launch: generated a new gateway token (stored in Keychain). New clients must present it to connect:")
            print("   \(fresh)")
        } else {
            print("⚠️ [ApexGatewayServer] Keychain unavailable; gateway token is in-memory only for this session.")
        }
        return fresh
    }
    
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ApexGatewayServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }

        // C2: ensure the pre-shared auth token exists (generated once,
        // stored in the Keychain, shown to the user on first generation).
        _ = Self.gatewayToken()

        // C2: loopback-only exposure. Network.framework rejects
        // `requiredLocalEndpoint` on NWListener (EINVAL at listener init —
        // proven in isolation on macOS 27, AUDIT_2026-09-28 follow-up), so we
        // bind normally and enforce loopback at accept time: any connection
        // whose local path is not a loopback endpoint is cancelled (fail
        // closed). This keeps the security property the original code intended
        // without the API misuse that broke every bind.
        let params = NWParameters.tcp
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        // Surface bind failures synchronously through `start()` instead of
        // only printing in the background (silent-bind-failure note, P2.5).
        let started = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("📡 [ApexGatewayServer] Daemon ready and listening on port \(self?.port ?? 0)")
                started.signal()
            case .failed(let error):
                print("⚠️ [ApexGatewayServer] Listener failed: \(error)")
                startError = error
                started.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            // C2 accept-time loopback guard.
            let localEndpoint = connection.currentPath?.localEndpoint
            var isLoopback = false
            var hostString = ""
            if case .hostPort(let host, _) = localEndpoint {
                switch host {
                case .name(let name, _):
                    hostString = name
                    isLoopback = name.caseInsensitiveCompare("localhost") == .orderedSame
                case .ipv4(let addr):
                    hostString = addr.debugDescription
                    isLoopback = addr.debugDescription.hasPrefix("127.")
                case .ipv6(let addr):
                    hostString = addr.debugDescription
                    isLoopback = hostString == "::1"
                @unknown default:
                    isLoopback = false
                }
            }
            guard isLoopback else {
                print("📡 [ApexGatewayServer] Rejected non-loopback connection: \(String(describing: localEndpoint)) host=\(hostString)")
                connection.cancel()
                return
            }
            Task { [weak self] in
                await self?.registerConnection(connection)
            }
        }

        listener.start(queue: .global(qos: .userInteractive))
        if started.wait(timeout: .now() + 2) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw NSError(domain: "ApexGatewayServer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Listener did not become ready within 2s on port \(port)"])
        }
        if let startError {
            listener.cancel()
            self.listener = nil
            throw startError
        }
    }
    
    public func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections.values {
            conn.cancel()
        }
        connections.removeAll()
        SessionLifecycleManager.shared.cancelAll()
        print("📡 [ApexGatewayServer] Daemon stopped.")
    }
    
    private func registerConnection(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        print("📡 [ApexGatewayServer] Client connected: \(id)")
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                print("📡 [ApexGatewayServer] Connection \(id) failed: \(error)")
                Task { @MainActor [weak self] in
                    self?.connections.removeValue(forKey: id)
                    self?.authenticatedConnections.remove(id)
                    SessionLifecycleManager.shared.cancelSession(id: id)
                }
            case .cancelled:
                print("📡 [ApexGatewayServer] Connection \(id) cancelled")
                Task { @MainActor [weak self] in
                    self?.connections.removeValue(forKey: id)
                    self?.authenticatedConnections.remove(id)
                    SessionLifecycleManager.shared.cancelSession(id: id)
                }
            default:
                break
            }
        }
        
        connection.start(queue: .global())
        
        // Start reading message frames; state is sent only after authentication.
        readNextMessage(from: connection, id: id)
    }
    
    private func readNextMessage(from connection: NWConnection, id: UUID) {
        // Read prefix length (4 bytes UInt32 big-endian)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            if let error {
                print("📡 [ApexGatewayServer] Receive error: \(error)")
                return
            }
            guard let content, content.count == 4 else {
                if isComplete { connection.cancel() }
                return
            }
            
            let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // C2: cap the frame length — an unbounded UInt32 lets a client
            // force a multi-GB allocation (DoS).
            guard length <= Self.maxFrameBytes else {
                print("📡 [ApexGatewayServer] Client \(id) sent oversize frame (\(length) bytes); closing connection.")
                connection.cancel()
                return
            }
            
            // Read body payload
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] bodyContent, _, bodyComplete, bodyError in
                if let bodyError {
                    print("📡 [ApexGatewayServer] Body receive error: \(bodyError)")
                    return
                }
                guard let bodyContent, bodyContent.count == Int(length) else {
                    if bodyComplete { connection.cancel() }
                    return
                }
                
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let action = try? JSONDecoder().decode(GatewayAction.self, from: bodyContent) {
                        await self.handleClientAction(action, connectionId: id)
                    }
                    self.readNextMessage(from: connection, id: id)
                }
            }
        }
    }
    
    private func handleClientAction(_ action: GatewayAction, connectionId: UUID) async {
        // C2: no client action is honored until the pre-shared token is presented.
        if case .authenticate(let token) = action {
            if !token.isEmpty, token == authenticationToken {
                authenticatedConnections.insert(connectionId)
                print("📡 [ApexGatewayServer] Client \(connectionId) authenticated.")
                // Send initial state only to the newly authenticated client, not all.
                broadcastState()
            } else {
                print("⚠️ [ApexGatewayServer] Client \(connectionId) failed gateway authentication; closing connection.")
                connections[connectionId]?.cancel()
            }
            return
        }
        guard authenticatedConnections.contains(connectionId) else { return }

        switch action {
        case .sendMessage(let text, let attachmentsData):
            let attachments = attachmentsData.compactMap { NSImage(data: $0) }
            orchestrator.pendingAttachments = attachments
            let task = Task { @MainActor [weak orchestrator] in
                guard let orchestrator else { return }
                orchestrator.sendMessage(text)
            }
            SessionLifecycleManager.shared.register(task: task, forSessionId: connectionId)
            
        case .cancelGeneration:
            orchestrator.cancelGeneration()
            SessionLifecycleManager.shared.cancelSession(id: connectionId)
            
        case .resolveConfirmation(let id, let approved):
            _ = SessionLifecycleManager.shared.resolveConfirmation(requestId: id, approved: approved)
        default:
            break
        }
    }

    private func requestRemoteConfirmation(toolName: String, arguments: String, riskDescription: String) async -> Bool {
        let reqId = UUID()
        let sanitizedArgs = SecurityAuditor.redactSensitiveData(in: arguments)
        let action = GatewayAction.requestConfirmation(id: reqId, toolName: toolName, arguments: sanitizedArgs, riskDescription: riskDescription)
        
        broadcastMessage(action)
        
        // C3: bounded wait — resume false after 60 s if the client never responds.
        return await withCheckedContinuation { continuation in
            SessionLifecycleManager.shared.registerConfirmation(requestId: reqId, continuation: continuation)
            Task {
                try? await Task.sleep(for: .seconds(60))
                // Resolve as denied if the confirmation was never answered.
                _ = SessionLifecycleManager.shared.resolveConfirmation(requestId: reqId, approved: false)
            }
        }
    }
    
    private func broadcastState() {
        let codableMessages = orchestrator.messages.map { msg in
            let codableRole: CodableMessageRole
            switch msg.role {
            case .user: codableRole = .user
            case .assistant: codableRole = .assistant
            case .system: codableRole = .system
            }
            
            let codableTools = msg.toolEvents.map { ev in
                CodableToolEvent(
                    id: ev.id,
                    toolName: ev.toolName,
                    status: String(describing: ev.status),
                    riskDescription: nil,
                    arguments: SecurityAuditor.redactSensitiveData(in: ev.arguments),
                    result: SecurityAuditor.redactSensitiveData(in: ev.result ?? ""),
                    timestamp: ev.timestamp
                )
            }
            
            let pngs = msg.attachments.compactMap { img -> Data? in
                guard let tiff = img.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
                return bitmap.representation(using: .png, properties: [:])
            }
            
            return CodableChatMessage(
                id: msg.id,
                role: codableRole,
                content: msg.content,
                toolEvents: codableTools,
                timestamp: msg.timestamp,
                isStreaming: msg.isStreaming,
                attachmentPNGs: pngs
            )
        }
        
        let action = GatewayAction.stateUpdate(
            messages: codableMessages,
            isGenerating: orchestrator.isGenerating,
            activeAssistantMessageId: orchestrator.activeAssistantMessageId
        )
        
        broadcastMessage(action)

        if let terminalMessage = orchestrator.messages.last(where: { $0.role == .assistant && !$0.isStreaming }),
           terminalMessage.id != lastTerminalMessageId,
           Self.isTerminalErrorMessage(terminalMessage.content) {
            lastTerminalMessageId = terminalMessage.id
            broadcastMessage(.terminalResult(message: terminalMessage.content, isError: true))
        }
    }

    private static func isTerminalErrorMessage(_ content: String) -> Bool {
        content.hasPrefix("⚠️")
            || content.hasPrefix("Generation cancelled")
            || content.hasPrefix("The request failed")
            || content.hasPrefix("The request could not be completed")
            || content.hasPrefix("The request timed out")
            || content.hasPrefix("The provider returned no response")
            || content.hasPrefix("All available providers failed")
    }
    
    private func broadcastMessage(_ action: GatewayAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let fullPacket = lengthData + data
        
        // C2: send only to authenticated peers — never broadcast to
        // unauthenticated connections (info leak / pre-auth injection risk).
        for (id, conn) in connections where authenticatedConnections.contains(id) {
            conn.send(content: fullPacket, completion: .contentProcessed { error in
                if let error {
                    print("⚠️ [ApexGatewayServer] Broadcast failed: \(error)")
                }
            })
        }
    }

    // MARK: - Markdown Telemetry

    public func formatServerStatusMarkdown() -> String {
        var md = "### 📡 Apex Gateway Server Status\n\n"
        md += "| Parameter | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Listen Port | `\(port)` | TCP socket listener port |\n"
        md += "| Active Sockets | `\(connections.count)` | Open client connections |\n"
        md += "| Authenticated Clients | `\(authenticatedConnections.count)` | Authenticated client sessions |\n"
        md += "| Max Inbound Frame | `\(Self.maxFrameBytes / (1024 * 1024)) MB` | Bounded payload size |\n"
        return md
    }

}