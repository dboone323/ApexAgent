import Foundation

// MARK: - Session Lifecycle Manager
//
// Manages per-session and per-request generation tasks, child processes, URL streams,
// and confirmation continuations to ensure guaranteed cleanup and reliable cancellation.

@MainActor
public final class SessionLifecycleManager {
    public static let shared = SessionLifecycleManager()

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeProcesses: [UUID: Set<Process>] = [:]
    private var pendingConfirmations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var sessionConfirmations: [UUID: Set<UUID>] = [:]

    public init() {}

    // MARK: - Generation Tasks

    public func register(task: Task<Void, Never>, forSessionId sessionId: UUID) {
        // Cancel existing task if any
        if let existing = activeTasks[sessionId] {
            existing.cancel()
        }
        activeTasks[sessionId] = task
    }

    public func unregister(sessionId: UUID) {
        activeTasks.removeValue(forKey: sessionId)
    }

    // MARK: - Child Subprocesses

    public func register(process: Process, forSessionId sessionId: UUID) {
        var set = activeProcesses[sessionId] ?? Set<Process>()
        set.insert(process)
        activeProcesses[sessionId] = set
    }

    public func unregister(process: Process, forSessionId sessionId: UUID) {
        guard var set = activeProcesses[sessionId] else { return }
        set.remove(process)
        if set.isEmpty {
            activeProcesses.removeValue(forKey: sessionId)
        } else {
            activeProcesses[sessionId] = set
        }
    }

    // MARK: - Confirmation Continuations

    public func registerConfirmation(
        requestId: UUID,
        sessionId: UUID? = nil,
        continuation: CheckedContinuation<Bool, Never>
    ) {
        pendingConfirmations[requestId] = continuation
        if let sessionId = sessionId {
            var set = sessionConfirmations[sessionId] ?? Set<UUID>()
            set.insert(requestId)
            sessionConfirmations[sessionId] = set
        }
    }

    public func resolveConfirmation(requestId: UUID, approved: Bool) -> Bool {
        guard let continuation = pendingConfirmations.removeValue(forKey: requestId) else {
            return false
        }
        continuation.resume(returning: approved)
        // Clean up from session mapping
        for (sessId, var reqSet) in sessionConfirmations {
            if reqSet.contains(requestId) {
                reqSet.remove(requestId)
                sessionConfirmations[sessId] = reqSet
                break
            }
        }
        return true
    }

    // MARK: - Cancellation & Teardown

    public func cancelSession(id: UUID, reason: String = "User requested cancellation") {
        // 1. Cancel generation task
        if let task = activeTasks.removeValue(forKey: id) {
            task.cancel()
        }

        // 2. Terminate child processes
        if let processes = activeProcesses.removeValue(forKey: id) {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }

        // 3. Reject pending confirmations for this session
        if let reqIds = sessionConfirmations.removeValue(forKey: id) {
            for reqId in reqIds {
                if let continuation = pendingConfirmations.removeValue(forKey: reqId) {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    public func cancelAll() {
        for (_, task) in activeTasks {
            task.cancel()
        }
        activeTasks.removeAll()

        for (_, processes) in activeProcesses {
            for process in processes where process.isRunning {
                process.terminate()
            }
        }
        activeProcesses.removeAll()

        for (_, continuation) in pendingConfirmations {
            continuation.resume(returning: false)
        }
        pendingConfirmations.removeAll()
        sessionConfirmations.removeAll()
    }
}
