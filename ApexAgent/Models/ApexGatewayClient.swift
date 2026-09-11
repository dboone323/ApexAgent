import Foundation
import Network
import Observation
import SwiftUI

@MainActor
@Observable
final class ApexGatewayClient {
    static let shared = ApexGatewayClient()
    
    // Observed state variables mirroring the server orchestrator state
    var messages: [CodableChatMessage] = []
    var isGenerating: Bool = false
    var activeAssistantMessageId: UUID?
    var pendingConfirmation: ConfirmationRequest?
    var isConnected: Bool = false
    
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "apex.gateway.client")
    private var retryAttempt = 0
    /// Counts consecutive connection-refused errors. The gateway server is a
    /// separate peer-coordination process the app does not auto-start, so a
    /// refused connection means "not available" — stop retrying after a few
    /// attempts instead of logging "Connection refused" every 30s forever.
    private var refusedAttempts = 0
    private let maxRefusedAttempts = 3
    
    init() {}
    
    /// Quickly checks if a gateway server is listening before opening a full NWConnection,
    /// avoiding noisy Network.framework ECONNREFUSED logs when running standalone.
    public static func isServerReachable(host: String = "127.0.0.1", port: UInt16 = 1337) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        
        var tv = timeval(tv_sec: 0, tv_usec: 150_000) // 150ms
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return res == 0
    }
    
    public func connect(host: String = "127.0.0.1", port: UInt16 = 1337) {
        guard connection == nil else { return }
        
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("📡 [ApexGatewayClient] Connected to daemon.")
                Task { @MainActor in
                    self.isConnected = true
                    self.retryAttempt = 0
                }
            case .failed(let error):
                Task { @MainActor in
                    var isRefused = false
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        isRefused = true
                    }
                    if !isRefused && self.retryAttempt < 3 {
                        print("📡 [ApexGatewayClient] Connection failed: \(error)")
                    }
                    self.handleDisconnect(for: connection, isConnectionRefused: isRefused)
                }
            case .cancelled:
                print("📡 [ApexGatewayClient] Connection cancelled")
                Task { @MainActor in
                    self.handleDisconnect(for: connection)
                }
            default:
                break
            }
        }
        
        connection.start(queue: queue)
        
        // Start reading message frames
        readNextMessage(from: connection)
    }
    
    public func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        isGenerating = false
    }
    
    private func handleDisconnect(for connection: NWConnection, isConnectionRefused: Bool = false) {
        Task { @MainActor in
            guard self.connection === connection else { return }
            
            self.connection = nil
            self.isConnected = false
            self.isGenerating = false
            
            // Bypass background reconnect in test mode to prevent task leaks
            let isTesting = ProcessInfo.processInfo.arguments.contains { $0.contains("test") || $0.contains("xctest") } || ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
            guard !isTesting else { return }
            
            if isConnectionRefused {
                self.refusedAttempts += 1
                if self.refusedAttempts >= self.maxRefusedAttempts {
                    // Gateway server isn't running (this app doesn't start it).
                    // Stop hammering the port; surface one clear message and stay
                    // disconnected. The user can start the gateway separately.
                    if self.refusedAttempts == self.maxRefusedAttempts {
                        print("📡 [ApexGatewayClient] Gateway server not reachable at 127.0.0.1:1337 — peer coordination disabled (start ApexGatewayServer to enable).")
                    }
                    return
                }
                // Log the first few refused attempts, then go quiet.
                print("📡 [ApexGatewayClient] Gateway server not reachable at 127.0.0.1:1337 (attempt \(self.refusedAttempts)/\(self.maxRefusedAttempts)). Retrying…")
                do {
                    try await Task.sleep(for: .seconds(30))
                    self.connect()
                } catch {
                    print("📡 [ApexGatewayClient] Reconnect task cancelled.")
                }
                return
            }

            self.retryAttempt += 1
            let delay = min(3.0 * pow(1.5, Double(self.retryAttempt)), 60.0)
            
            if self.retryAttempt <= 3 {
                print("📡 [ApexGatewayClient] Disconnected. Retrying in \(String(format: "%.1f", delay))s...")
            }
            
            do {
                try await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                self.connect()
            } catch {
                print("📡 [ApexGatewayClient] Reconnect task cancelled.")
            }
        }
    }
    
    public func sendMessage(_ text: String, attachments: [Data]) {
        sendAction(.sendMessage(text: text, attachments: attachments))
    }
    
    public func cancelGeneration() {
        sendAction(.cancelGeneration)
    }
    
    public func resolveConfirmation(id: UUID, approved: Bool) {
        Task { @MainActor in
            if self.pendingConfirmation?.id == id {
                self.pendingConfirmation = nil
            }
        }
        sendAction(.resolveConfirmation(id: id, approved: approved))
    }
    
    private func sendAction(_ action: GatewayAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        let fullPacket = lengthData + data
        
        connection?.send(content: fullPacket, completion: .contentProcessed { error in
            if let error {
                print("⚠️ [ApexGatewayClient] Send failed: \(error)")
            }
        })
    }
    
    private func readNextMessage(from connection: NWConnection) {
        // Read prefix length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in
                    var isRefused = false
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        isRefused = true
                    }
                    if !isRefused && self.retryAttempt < 3 {
                        print("📡 [ApexGatewayClient] Receive error: \(error)")
                    }
                    self.handleDisconnect(for: connection, isConnectionRefused: isRefused)
                }
                return
            }
            guard let content, content.count == 4 else {
                if isComplete {
                    Task { @MainActor in
                        self.handleDisconnect(for: connection)
                    }
                }
                return
            }
            
            let length = content.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            
            // Read body payload
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] bodyContent, _, bodyComplete, bodyError in
                guard let self else { return }
                if let bodyError {
                    Task { @MainActor in
                        var isRefused = false
                        if case .posix(let code) = bodyError, code == .ECONNREFUSED {
                            isRefused = true
                        }
                        if !isRefused && self.retryAttempt < 3 {
                            print("📡 [ApexGatewayClient] Body receive error: \(bodyError)")
                        }
                        self.handleDisconnect(for: connection, isConnectionRefused: isRefused)
                    }
                    return
                }
                guard let bodyContent, bodyContent.count == Int(length) else {
                    if bodyComplete {
                        Task { @MainActor in
                            self.handleDisconnect(for: connection)
                        }
                    }
                    return
                }
                
                if let action = try? JSONDecoder().decode(GatewayAction.self, from: bodyContent) {
                    Task { @MainActor in
                        self.handleServerAction(action)
                    }
                }
                
                // Read next packet
                Task { @MainActor in
                    self.readNextMessage(from: connection)
                }
            }
        }
    }
    
    @MainActor
    private func handleServerAction(_ action: GatewayAction) {
        switch action {
        case .stateUpdate(let messages, let isGenerating, let activeId):
            self.messages = messages
            self.isGenerating = isGenerating
            self.activeAssistantMessageId = activeId
            
        case .requestConfirmation(let id, let toolName, let arguments, let riskDescription):
            self.pendingConfirmation = ConfirmationRequest(
                id: id,
                toolName: toolName,
                arguments: arguments,
                riskDescription: riskDescription,
                oldContent: nil,
                newContent: nil,
                filePath: nil,
                continuation: nil
            )
            
        default:
            break
        }
    }
}
