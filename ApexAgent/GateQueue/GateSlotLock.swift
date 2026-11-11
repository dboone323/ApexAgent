import Foundation
import Darwin

/// Errors that can occur during gate slot lock operations.
public enum GateLockError: Error, LocalizedError, Sendable, Equatable {
    case staleLock(owner: String, timestamp: Date)
    case timedOut(lockDirectory: String, waitedSeconds: Double)
    case cannotCreateLockDirectory(String)

    public var errorDescription: String? {
        switch self {
        case .staleLock(let owner, let timestamp):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return "Gate lock is stale (owner: '\(owner)', timestamp: '\(formatter.string(from: timestamp))' > 60 minutes old). Execution stopped."
        case .timedOut(let dir, let waited):
            return "Timed out after \(Int(waited))s waiting for gate lock slot at '\(dir)'."
        case .cannotCreateLockDirectory(let msg):
            return "Failed to create gate lock directory: \(msg)"
        }
    }
}

/// Coordinates machine-wide gate slot discipline using atomic directory creation (`gate.lock.d`).
/// Enforces strict serialization: only one gate executes at a time across all projects.
public final class GateSlotLock: Sendable {
    public let lockDirectoryURL: URL
    public let staleTimeout: TimeInterval
    public let pollInterval: TimeInterval

    public init(
        lockDirectoryURL: URL? = nil,
        staleTimeout: TimeInterval = 3600, // 60 minutes
        pollInterval: TimeInterval = 60     // 60 seconds
    ) {
        if let explicit = lockDirectoryURL {
            self.lockDirectoryURL = explicit
        } else if let env = ProcessInfo.processInfo.environment["APEX_GATE_LOCK_DIR"], !env.isEmpty {
            self.lockDirectoryURL = URL(fileURLWithPath: env, isDirectory: true)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.lockDirectoryURL = home.appendingPathComponent("Developer/ApexAgent/runs/gate.lock.d", isDirectory: true)
        }
        self.staleTimeout = staleTimeout
        self.pollInterval = pollInterval
    }

    /// Owner file URL inside the lock directory.
    public var ownerFileURL: URL {
        lockDirectoryURL.appendingPathComponent("owner")
    }

    /// Checks if the lock is currently held.
    public var isLocked: Bool {
        FileManager.default.fileExists(atPath: lockDirectoryURL.path)
    }

    /// Reads the current owner information and timestamp if the lock exists.
    public func readCurrentOwner() -> (owner: String, timestamp: Date)? {
        guard let data = try? Data(contentsOf: ownerFileURL),
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        let parts = content.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return (content, Date.distantPast)
        }
        let owner = parts[0]
        let dateString = parts[1]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: dateString) {
            return (owner, date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: dateString) {
            return (owner, date)
        }
        return (owner, Date.distantPast)
    }

    /// Attempts to acquire the gate slot lock atomically.
    /// If the lock is held, waits and polls up to `maxWaitTime` (or indefinitely if `maxWaitTime` is nil).
    /// If the existing lock is older than `staleTimeout`, aborts with `.staleLock`.
    public func acquire(
        owner: String,
        maxWaitTime: TimeInterval? = nil,
        checkCancellation: (@Sendable () -> Bool)? = nil
    ) async throws {
        let startTime = Date()
        let lockPath = lockDirectoryURL.path

        // Ensure parent directory exists
        let parentDir = lockDirectoryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        while true {
            if let check = checkCancellation, check() {
                throw CancellationError()
            }

            // Atomic mkdir call using POSIX mkdir
            let result = mkdir(lockPath, 0o755)
            if result == 0 {
                // Successfully created lock directory! Write owner file.
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                let nowString = formatter.string(from: Date())
                let ownerContent = "\(owner) \(nowString)\n"
                try? ownerContent.data(using: .utf8)?.write(to: ownerFileURL, options: .atomic)
                return
            }

            let err = errno
            if err == EEXIST {
                // Lock already exists. Inspect owner and timestamp.
                if let (currentOwner, timestamp) = readCurrentOwner() {
                    let age = Date().timeIntervalSince(timestamp)
                    if age > staleTimeout {
                        throw GateLockError.staleLock(owner: currentOwner, timestamp: timestamp)
                    }
                }

                // Check overall timeout if specified
                if let maxWait = maxWaitTime {
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed >= maxWait {
                        throw GateLockError.timedOut(lockDirectory: lockPath, waitedSeconds: elapsed)
                    }
                }

                // Wait before retrying (wait-instead-of-stop)
                let sleepDuration = UInt64(pollInterval * 1_000_000_000)
                try await Task.sleep(nanoseconds: sleepDuration)
            } else {
                let errorMsg = String(cString: strerror(err))
                throw GateLockError.cannotCreateLockDirectory("errno \(err): \(errorMsg) at \(lockPath)")
            }
        }
    }

    /// Releases the gate slot lock by removing the lock directory.
    public func release() {
        if FileManager.default.fileExists(atPath: lockDirectoryURL.path) {
            try? FileManager.default.removeItem(at: lockDirectoryURL)
        }
    }

    /// Executes an operation while holding the gate slot lock, ensuring release on exit.
    public func withLock<T: Sendable>(
        owner: String,
        maxWaitTime: TimeInterval? = nil,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(owner: owner, maxWaitTime: maxWaitTime)
        do {
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
