import Foundation
import FoundationModels
import Network

struct NetworkDiagnosticsTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "network_diagnostics"
    let description = "Network status and endpoint probing."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "Action to perform: 'status', 'probe', or 'dns'")
        var action: String
        
        @Guide(description: "Host to probe or resolve (required for probe/dns)")
        var host: String?
        
        @Guide(description: "Port to probe (default 443)")
        var port: Int?
        
        @Guide(description: "Timeout in seconds (default 10)")
        var timeoutSeconds: Int?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator, riskDescription: nil) {
            switch arguments.action {
            case "status":
                let monitor = NWPathMonitor()
                let path: NWPath = await withCheckedContinuation { cont in
                    monitor.pathUpdateHandler = { path in
                        cont.resume(returning: path)
                        monitor.cancel()
                    }
                    monitor.start(queue: .global())
                }
                
                var interfaceType = "unknown"
                if path.usesInterfaceType(.wifi) { interfaceType = "wifi" } else if path.usesInterfaceType(.cellular) { interfaceType = "cellular" } else if path.usesInterfaceType(.wiredEthernet) { interfaceType = "wiredEthernet" }
                
                return """
                Interface Type: \(interfaceType)
                Is Constrained: \(path.isConstrained)
                Is Expensive: \(path.isExpensive)
                Supports DNS: \(path.supportsDNS)
                Supports IPv4: \(path.supportsIPv4)
                Supports IPv6: \(path.supportsIPv6)
                """
                
            case "probe":
                guard let host = arguments.host else { return "ERROR: host required for probe" }
                let port = arguments.port ?? 443
                let timeout = arguments.timeoutSeconds ?? 10
                
                let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!)
                let connection = NWConnection(to: endpoint, using: .tcp)
                let startTime = CFAbsoluteTimeGetCurrent()
                
                return try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask {
                        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                            connection.stateUpdateHandler = { state in
                                switch state {
                                case .ready:
                                    let latency = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
                                    cont.resume(returning: String(format: "Connected to %@:%d (Latency: %.2f ms)", host, port, latency))
                                    connection.cancel()
                                case .failed(let error):
                                    cont.resume(throwing: error)
                                case .cancelled:
                                    cont.resume(throwing: NSError(domain: "NetworkDiagnosticsTool", code: -1, userInfo: [NSLocalizedDescriptionKey: "Connection cancelled"]))
                                default:
                                    break
                                }
                            }
                            connection.start(queue: .global())
                        }
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                        connection.cancel()
                        throw NSError(domain: "NetworkDiagnosticsTool", code: -2, userInfo: [NSLocalizedDescriptionKey: "Probe timed out after \(timeout) seconds."])
                    }
                    
                    let first = try await group.next()!
                    group.cancelAll()
                    return first
                }
                
            case "dns":
                guard let host = arguments.host else { return "ERROR: host required for dns" }
                
                return try await withCheckedThrowingContinuation { cont in
                    DispatchQueue.global().async {
                        var hints = addrinfo()
                        hints.ai_family = AF_UNSPEC
                        hints.ai_socktype = SOCK_STREAM
                        
                        var res: UnsafeMutablePointer<addrinfo>?
                        let status = getaddrinfo(host, nil, &hints, &res)
                        
                        if status != 0 {
                            cont.resume(throwing: NSError(domain: "NetworkDiagnosticsTool", code: Int(status), userInfo: [NSLocalizedDescriptionKey: String(cString: gai_strerror(status))]))
                            return
                        }
                        
                        var ips: [String] = []
                        var ptr = res
                        while let info = ptr {
                            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                            getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                            hostname.withUnsafeBufferPointer { ptr in
                                if let base = ptr.baseAddress {
                                    ips.append(String(cString: base))
                                }
                            }
                            ptr = info.pointee.ai_next
                        }
                        
                        freeaddrinfo(res)
                        cont.resume(returning: "Resolved IPs for \(host):\n\(ips.joined(separator: "\n"))")
                    }
                }
                
            default:
                return "ERROR: Invalid action '\(arguments.action)'"
            }
        }
    }
}
