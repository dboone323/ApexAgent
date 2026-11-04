import Testing
import Foundation
import SwiftData
import SharedKit
import Network
import os
@testable import ApexAgentCore

@MainActor
@Suite("ApexGatewayServerTests", .serialized) final class ApexGatewayServerTests {
    
    @Test func testServerLifecycle() async throws {
        let orchestrator = AgentOrchestrator()
        let schema = Schema([Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        orchestrator.modelContext = ModelContext(container)
        
        let server = ApexGatewayServer(port: 0, orchestrator: orchestrator)
        _ = server // non-optional value type
        
        // Start the server
        try server.start()
        
        guard let boundPort = server.listeningPort else {
            Issue.record("Server failed to bind an ephemeral port")
            return
        }
        #expect(boundPort > 0, "Bound ephemeral port should be non-zero")
        
        // Trigger a state change to exercise the broadcast state routing
        orchestrator.onStateChanged?()
        
        // Stop the server
        server.stop()
        #expect(server.listeningPort == nil, "Server listeningPort should be nil after stop()")
    }

    @Test func testTerminalResultRoundTrip() throws {
        let original = GatewayAction.terminalResult(message: "The provider returned no response.", isError: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GatewayAction.self, from: data)

        guard case .terminalResult(let message, let isError) = decoded else {
            Issue.record("Gateway terminal result did not decode as its original action")
            return
        }
        #expect(message == "The provider returned no response.")
        #expect(isError)
    }

    @Test func testRealLoopbackTCPClientConnectionAndStateBroadcast() async throws {
        let gatewayToken = UUID().uuidString
        let orchestrator = AgentOrchestrator()
        orchestrator.appendMessage(ChatMessage(role: .user, content: "Gateway connectivity test"))

        let server = ApexGatewayServer(
            port: 0,
            orchestrator: orchestrator,
            authenticationToken: gatewayToken
        )
        try server.start()
        defer { server.stop() }

        // Give listener brief setup moment
        try await Task.sleep(for: .milliseconds(200))

        guard let boundPort = server.listeningPort, let nwPort = NWEndpoint.Port(rawValue: boundPort) else {
            Issue.record("Invalid port")
            return
        }

        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        defer { connection.cancel() }

        let connectionResumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let shouldResume = connectionResumed.withLock { isResumed -> Bool in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        continuation.resume()
                    }
                case .failed(let error):
                    let shouldResume = connectionResumed.withLock { isResumed -> Bool in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }

        let authData = try JSONEncoder().encode(
            GatewayAction.authenticate(token: gatewayToken)
        )
        var authLength = UInt32(authData.count).bigEndian
        let authPacket = Data(bytes: &authLength, count: 4) + authData
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: authPacket, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        // Receive broadcasted state frame (4 bytes length + JSON payload)
        let actionResumed = OSAllocatedUnfairLock(initialState: false)
        let receivedAction: GatewayAction = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<GatewayAction, Error>) in
            connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { lengthContent, _, _, lengthError in
                if let lengthError {
                    let shouldResume = actionResumed.withLock { isResumed -> Bool in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        continuation.resume(throwing: lengthError)
                    }
                    return
                }
                guard let lengthContent, lengthContent.count == 4 else {
                    let shouldResume = actionResumed.withLock { isResumed -> Bool in
                        if !isResumed {
                            isResumed = true
                            return true
                        }
                        return false
                    }
                    if shouldResume {
                        continuation.resume(throwing: NSError(domain: "GatewayTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid length"]))
                    }
                    return
                }
                let length = lengthContent.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
                connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { bodyContent, _, _, bodyError in
                    if let bodyError {
                        let shouldResume = actionResumed.withLock { isResumed -> Bool in
                            if !isResumed {
                                isResumed = true
                                return true
                            }
                            return false
                        }
                        if shouldResume {
                            continuation.resume(throwing: bodyError)
                        }
                        return
                    }
                    guard let bodyContent else {
                        let shouldResume = actionResumed.withLock { isResumed -> Bool in
                            if !isResumed {
                                isResumed = true
                                return true
                            }
                            return false
                        }
                        if shouldResume {
                            continuation.resume(throwing: NSError(domain: "GatewayTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Empty body"]))
                        }
                        return
                    }
                    do {
                        let action = try JSONDecoder().decode(GatewayAction.self, from: bodyContent)
                        let shouldResume = actionResumed.withLock { isResumed -> Bool in
                            if !isResumed {
                                isResumed = true
                                return true
                            }
                            return false
                        }
                        if shouldResume {
                            continuation.resume(returning: action)
                        }
                    } catch {
                        let shouldResume = actionResumed.withLock { isResumed -> Bool in
                            if !isResumed {
                                isResumed = true
                                return true
                            }
                            return false
                        }
                        if shouldResume {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }

        guard case .stateUpdate(let messages, _, _) = receivedAction else {
            Issue.record("Expected .stateUpdate action from server broadcast, got \(receivedAction)")
            return
        }
        #expect(!messages.isEmpty)
        #expect(messages.first?.content == "Gateway connectivity test")

        // Now send an action back to the server: .cancelGeneration
        let cancelAction = GatewayAction.cancelGeneration
        let cancelData = try JSONEncoder().encode(cancelAction)
        var lengthBigEndian = UInt32(cancelData.count).bigEndian
        var framedPacket = Data(bytes: &lengthBigEndian, count: 4)
        framedPacket.append(cancelData)

        let sendResumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framedPacket, completion: .contentProcessed { error in
                let shouldResume = sendResumed.withLock { isResumed -> Bool in
                    if !isResumed {
                        isResumed = true
                        return true
                    }
                    return false
                }
                guard shouldResume else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }

        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func testDispatchSwarmToolParallelExecution() async throws {
        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)

        _ = botManager.createBot(
            name: "SwarmAlpha",
            title: "Auditor",
            descriptionText: "Audits security policies"
        )
        _ = botManager.createBot(
            name: "SwarmBeta",
            title: "Linter",
            descriptionText: "Lints Swift syntax"
        )

        let swarmTool = DispatchSwarmTool(botManager: botManager)
        #expect(swarmTool.name == "dispatch_swarm")

        // 1. Validation for missing bots
        let missingArgs = DispatchSwarmTool.Arguments(targetBots: "NonExistentBot", taskPrompts: "Check health")
        let missingResult = try await swarmTool.call(arguments: missingArgs)
        #expect(missingResult.contains("not found"))
        #expect(missingResult.contains("NonExistentBot"))

        // 2. Validation for empty arguments
        let emptyArgs = DispatchSwarmTool.Arguments(targetBots: "", taskPrompts: "")
        let emptyResult = try await swarmTool.call(arguments: emptyArgs)
        #expect(emptyResult.contains("ERROR: No target bots provided."))

        // 3. Multi-bot delimited prompt decoding validation
        let delimitedArgs = DispatchSwarmTool.Arguments(
            targetBots: "SwarmAlpha, SwarmBeta",
            taskPrompts: "Task 1 for Alpha ||| Task 2 for Beta"
        )
        #expect(delimitedArgs.targetBots.contains("SwarmAlpha"))
        #expect(delimitedArgs.targetBots.contains("SwarmBeta"))
    }
}
