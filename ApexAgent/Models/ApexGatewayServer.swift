import Foundation
import AppKit
import Network

@MainActor
public final class ApexGatewayServer {
    private let port: UInt16
    private let orchestrator: AgentOrchestrator
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    
    private var lastTerminalMessageId: UUID?
    
    public init(port: UInt16 = 1337, orchestrator: AgentOrchestrator) {
        self.port = port
        self.orchestrator = orchestrator
        
        // Wire the orchestrator state change callback
        orchestrator.onStateChanged = { [weak self] in
            self?.broadcastState()
        }
        
        // Wire orchestrator confirmation interceptor
        orchestrator.confirmationGateway = { [weak self] toolName, arguments, riskDescription in
            await self?.requestRemoteConfirmation(toolName: toolName, arguments: arguments, riskDescription: riskDescription) ?? false
        }
    }
    
    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ApexGatewayServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }
        
        let listener = try NWListener(using: .tcp, on: nwPort)
        self.listener = listener
        
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("📡 [ApexGatewayServer] Daemon ready and listening on port \(self.port)")
            case .failed(let error):
                print("⚠️ [ApexGatewayServer] Listener failed: \(error)")
            default:
                break
            }
        }
        
        listener.newConnectionHandler = { [weak self] connection in
            Task { [weak self] in
                await self?.registerConnection(connection)
            }
        }
        
        listener.start(queue: .global(qos: .userInteractive))
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
                    SessionLifecycleManager.shared.cancelSession(id: id)
                }
            case .cancelled:
                print("📡 [ApexGatewayServer] Connection \(id) cancelled")
                Task { @MainActor [weak self] in
                    self?.connections.removeValue(forKey: id)
                    SessionLifecycleManager.shared.cancelSession(id: id)
                }
            default:
                break
            }
        }
        
        connection.start(queue: .global())
        
        // Start reading message frames
        readNextMessage(from: connection, id: id)
        
        // Immediately send initial state to the newly connected client
        broadcastState()
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
                        SessionLifecycleManager.shared.resolveConfirmation(requestId: id, approved: approved)
        default:
            break
        }
    }

    private func requestRemoteConfirmation(toolName: String, arguments: String, riskDescription: String) async -> Bool {
        let reqId = UUID()
        let sanitizedArgs = SecurityAuditor.redactSensitiveData(in: arguments)
        let action = GatewayAction.requestConfirmation(id: reqId, toolName: toolName, arguments: sanitizedArgs, riskDescription: riskDescription)
        
        broadcastMessage(action)
        
        return await withCheckedContinuation { continuation in
            SessionLifecycleManager.shared.registerConfirmation(requestId: reqId, continuation: continuation)
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
        
        for conn in connections.values {
            conn.send(content: fullPacket, completion: .contentProcessed { error in
                if let error {
                    print("⚠️ [ApexGatewayServer] Broadcast failed: \(error)")
                }
            })
        }
    }
}
