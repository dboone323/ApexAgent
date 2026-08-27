import Foundation
import AppKit

public enum ComputerAction: Equatable, Sendable, Codable {
    case click(x: Int, y: Int)
    case doubleClick(x: Int, y: Int)
    case type(text: String)
    case keyCombo(keys: [String])
    case scroll(deltaX: Int, deltaY: Int)
    case openApp(name: String)
    case wait(seconds: Double)
    case finish(result: String)
    case fail(reason: String)
}

public struct ComputerUseStep: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let turn: Int
    public let action: ComputerAction
    public let observation: String
    public let timestamp: Date
    
    public init(id: UUID = UUID(), turn: Int = 0, action: ComputerAction, observation: String = "", timestamp: Date = Date()) {
        self.id = id
        self.turn = turn
        self.action = action
        self.observation = observation
        self.timestamp = timestamp
    }
}

@MainActor @Observable public final class ComputerUseAgent {
    public static let shared = ComputerUseAgent()
    
    public private(set) var isRunning: Bool = false
    public private(set) var history: [ComputerUseStep] = []
    public var maxTurns: Int = 15
    
    private init() {}
    
    public func executeAction(_ action: ComputerAction) async throws -> String {
        switch action {
        case .click(let x, let y):
            // In a real implementation, we'd use CGEvent
            return "Clicked at (\(x), \(y))"
        case .doubleClick(let x, let y):
            return "Double clicked at (\(x), \(y))"
        case .type(let text):
            return "Typed text: \(text)"
        case .keyCombo(let keys):
            return "Pressed keys: \(keys.joined(separator: " + "))"
        case .scroll(let deltaX, let deltaY):
            return "Scrolled by (\(deltaX), \(deltaY))"
        case .openApp(let name):
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
                NSWorkspace.shared.open(url)
                return "Opened app: \(name)"
            }
            return "Failed to open app: \(name)"
        case .wait(let seconds):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return "Waited for \(seconds) seconds"
        case .finish(let result):
            return "Finished with result: \(result)"
        case .fail(let reason):
            return "Failed: \(reason)"
        }
    }
    
    public func runLoop(goal: String, onUpdate: @escaping (ComputerUseStep) -> Void) async throws -> String {
        isRunning = true
        defer { isRunning = false }
        
        history.removeAll()
        
        var currentTurn = 0
        while currentTurn < maxTurns {
            // Mocking the loop evaluation for now since there's no real LLM integrated here
            let action = currentTurn == maxTurns - 1 ? ComputerAction.finish(result: "Goal achieved: \(goal)") : ComputerAction.wait(seconds: 1.0)
            let observation = try await executeAction(action)
            
            let step = ComputerUseStep(turn: currentTurn, action: action, observation: observation)
            history.append(step)
            onUpdate(step)
            
            if case .finish(let result) = action {
                return result
            }
            if case .fail(let reason) = action {
                throw NSError(domain: "ComputerUseAgent", code: -1, userInfo: [NSLocalizedDescriptionKey: reason])
            }
            
            currentTurn += 1
        }
        
        throw NSError(domain: "ComputerUseAgent", code: -2, userInfo: [NSLocalizedDescriptionKey: "Max turns reached without completion"])
    }
}
