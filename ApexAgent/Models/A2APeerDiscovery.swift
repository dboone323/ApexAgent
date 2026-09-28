import Foundation
import Network
import Observation

@Observable
@MainActor
public final class A2APeerDiscovery {
    public static let shared = A2APeerDiscovery()
    
    public struct DiscoveredPeer: Identifiable, Sendable {
        public let id: UUID
        public let name: String
        public let endpoint: NWEndpoint
        public let discoveredAt: Date
    }
    
    public private(set) var discoveredPeers: [DiscoveredPeer] = []
    public private(set) var isAdvertising: Bool = false
    public private(set) var isBrowsing: Bool = false
    
    private var browser: NWBrowser?
    private var advertiser: NWListener?
    
    // Start advertising this node and browsing for peers
    public func startDiscovery(serviceName: String) throws {
        guard !isAdvertising && !isBrowsing else { return }
        
        // Start Browsing
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: "_apex-a2a._tcp", domain: nil)
        browser = NWBrowser(for: descriptor, using: .tcp)
        
        browser?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed(let error):
                    print("Browser failed with \(error)")
                    self?.isBrowsing = false
                case .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] _, changes in
            Task { @MainActor in
                guard let self = self else { return }
                for change in changes {
                    switch change {
                    case .added(let result):
                        let newPeer = DiscoveredPeer(
                            id: UUID(),
                            name: result.endpoint.debugDescription, // Ideally extract name from endpoint
                            endpoint: result.endpoint,
                            discoveredAt: Date()
                        )
                        self.discoveredPeers.append(newPeer)
                    case .removed(let result):
                        self.discoveredPeers.removeAll { $0.endpoint == result.endpoint }
                    default:
                        break
                    }
                }
            }
        }
        
        browser?.start(queue: .main)
        
        // Start Advertising
        let parameters = NWParameters.tcp
        let name = NWListener.Service(name: serviceName, type: "_apex-a2a._tcp")
            let listener = try NWListener(using: parameters)
            listener.service = name

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isAdvertising = true
                    case .failed(let error):
                        print("Advertiser failed with \(error)")
                        self?.isAdvertising = false
                    case .cancelled:
                        self?.isAdvertising = false
                    default:
                        break
                    }
                }
            }

            listener.start(queue: .main)
            self.advertiser = listener
    }
    
    // Stop all discovery
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        
        advertiser?.cancel()
        advertiser = nil
        isAdvertising = false
        
        discoveredPeers.removeAll()
    }
    
    // Fetch agent card from a discovered peer
    public func fetchAgentCard(from peer: DiscoveredPeer) async -> A2AAgentCard? {
        let endpoint = peer.endpoint
        // Extract host/port if possible, for simplicity use a direct connection
        let connection = NWConnection(to: endpoint, using: .tcp)
        
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let request = "GET /.well-known/agent.json HTTP/1.0\r\n\r\n"
                    connection.send(content: Data(request.utf8), completion: .contentProcessed({ error in
                        if error != nil {
                            connection.cancel()
                            continuation.resume(returning: nil)
                            return
                        }
                        
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                            if let data = data, let responseString = String(data: data, encoding: .utf8) {
                                let components = responseString.components(separatedBy: "\r\n\r\n")
                                if components.count >= 2, let bodyData = components[1].data(using: .utf8) {
                                    let decoder = JSONDecoder()
                                    let card = try? decoder.decode(A2AAgentCard.self, from: bodyData)
                                    continuation.resume(returning: card)
                                } else {
                                    continuation.resume(returning: nil)
                                }
                            } else {
                                continuation.resume(returning: nil)
                            }
                            connection.cancel()
                        }
                    }))
                case .failed, .cancelled:
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
        }
    }
}
