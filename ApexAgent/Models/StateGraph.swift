import Foundation

struct StateGraphState {
    var values: [String: Any] = [:]
}

enum StateGraphNodeResult {
    case success(output: String, nextState: StateGraphState)
    case failure(error: String, nextState: StateGraphState)
}

struct StateGraphNode {
    let name: String
    let execute: @MainActor (StateGraphState) async throws -> StateGraphNodeResult
}

struct StateGraphEdge {
    let fromNode: String
    let evaluate: @MainActor (String, Bool, StateGraphState) -> (String?, StateGraphState)
}

@MainActor
class StateGraph {
    let name: String
    private(set) var nodes: [String: StateGraphNode] = [:]
    private(set) var edges: [StateGraphEdge] = []
    var entryNode: String?
    
    init(name: String) {
        self.name = name
    }
    
    func addNode(name: String, execute: @escaping @MainActor (StateGraphState) async throws -> StateGraphNodeResult) {
        nodes[name] = StateGraphNode(name: name, execute: execute)
    }
    
    func addEdge(from: String, evaluate: @escaping @MainActor (String, Bool, StateGraphState) -> (String?, StateGraphState)) {
        edges.append(StateGraphEdge(fromNode: from, evaluate: evaluate))
    }
    
    func execute(initialState: StateGraphState, onNodeStart: @escaping @MainActor (String) -> Void) async throws -> StateGraphState {
        guard let entry = entryNode else {
            throw NSError(domain: "StateGraph", code: -1, userInfo: [NSLocalizedDescriptionKey: "Entry node is not set."])
        }
        
        var currentState = initialState
        var currentNodeName = entry
        
        while true {
            guard let node = nodes[currentNodeName] else {
                throw NSError(domain: "StateGraph", code: -1, userInfo: [NSLocalizedDescriptionKey: "Node \(currentNodeName) not found."])
            }
            
            onNodeStart(currentNodeName)
            
            let result = try await node.execute(currentState)
            
            var output = ""
            var isSuccess = true
            
            switch result {
            case .success(let nodeOutput, let nextState):
                output = nodeOutput
                currentState = nextState
                isSuccess = true
            case .failure(let nodeError, let nextState):
                output = nodeError
                currentState = nextState
                isSuccess = false
            }
            
            // Evaluate edges
            var nextNodeName: String? = nil
            for edge in edges where edge.fromNode == currentNodeName {
                let (next, updatedState) = edge.evaluate(output, isSuccess, currentState)
                if let next = next {
                    nextNodeName = next
                    currentState = updatedState
                    break
                }
            }
            
            if let next = nextNodeName {
                currentNodeName = next
            } else {
                break
            }
        }
        
        return currentState
    }
}
