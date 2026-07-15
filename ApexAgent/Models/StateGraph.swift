import Foundation

enum StateGraphStateError: Error, LocalizedError {
    case keyNotFound(String)
    case typeMismatch(expected: Any.Type, actual: Any.Type)
    
    var errorDescription: String? {
        switch self {
        case .keyNotFound(let key):
            return "Key '\(key)' not found in StateGraphState."
        case .typeMismatch(let expected, let actual):
            return "Type mismatch for StateGraphState value. Expected '\(expected)', got '\(actual)'."
        }
    }
}

struct StateGraphState {
    var values: [String: Any] = [:]
    
    func get<T>(_ key: String) throws -> T {
        guard let val = values[key] else {
            throw StateGraphStateError.keyNotFound(key)
        }
        guard let typedVal = val as? T else {
            throw StateGraphStateError.typeMismatch(expected: T.self, actual: type(of: val))
        }
        return typedVal
    }
    
    func getOptional<T>(_ key: String) throws -> T? {
        guard let val = values[key] else {
            return nil
        }
        guard let typedVal = val as? T else {
            throw StateGraphStateError.typeMismatch(expected: T.self, actual: type(of: val))
        }
        return typedVal
    }
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

enum StateGraphError: Error, LocalizedError {
    case cyclicExecution(nodeName: String)
    case maxIterationsReached
    case entryNodeNotSet
    case nodeNotFound(nodeName: String)
    
    var errorDescription: String? {
        switch self {
        case .cyclicExecution(let nodeName):
            return "Cyclic execution detected in state graph: node '\(nodeName)' was visited more than once."
        case .maxIterationsReached:
            return "Maximum state graph iterations reached (safety guard)."
        case .entryNodeNotSet:
            return "Entry node is not set."
        case .nodeNotFound(let nodeName):
            return "Node '\(nodeName)' not found."
        }
    }
}

@MainActor
class StateGraph {
    let name: String
    private let lock = NSLock()
    
    private var _nodes: [String: StateGraphNode] = [:]
    private var _edges: [StateGraphEdge] = []
    private var _entryNode: String?
    
    var nodes: [String: StateGraphNode] {
        lock.lock()
        defer { lock.unlock() }
        return _nodes
    }
    
    var edges: [StateGraphEdge] {
        lock.lock()
        defer { lock.unlock() }
        return _edges
    }
    
    var entryNode: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _entryNode
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _entryNode = newValue
        }
    }
    
    init(name: String) {
        self.name = name
    }
    
    func addNode(name: String, execute: @escaping @MainActor (StateGraphState) async throws -> StateGraphNodeResult) {
        lock.lock()
        defer { lock.unlock() }
        _nodes[name] = StateGraphNode(name: name, execute: execute)
    }
    
    func addEdge(from: String, evaluate: @escaping @MainActor (String, Bool, StateGraphState) -> (String?, StateGraphState)) {
        lock.lock()
        defer { lock.unlock() }
        _edges.append(StateGraphEdge(fromNode: from, evaluate: evaluate))
    }
    
    func execute(initialState: StateGraphState, onNodeStart: @escaping @MainActor (String) -> Void) async throws -> StateGraphState {
        guard let entry = entryNode else {
            throw StateGraphError.entryNodeNotSet
        }
        
        var currentState = initialState
        var currentNodeName = entry
        var visitedNodes: Set<String> = []
        var iterations = 0
        let maxIterations = 100
        
        while true {
            guard !visitedNodes.contains(currentNodeName) else {
                throw StateGraphError.cyclicExecution(nodeName: currentNodeName)
            }
            visitedNodes.insert(currentNodeName)
            
            iterations += 1
            if iterations > maxIterations {
                throw StateGraphError.maxIterationsReached
            }
            
            guard let node = nodes[currentNodeName] else {
                throw StateGraphError.nodeNotFound(nodeName: currentNodeName)
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
            let currentEdges = edges
            for edge in currentEdges where edge.fromNode == currentNodeName {
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
