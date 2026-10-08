import Foundation
import OSLog

// MARK: - AppLog: unified structured logging for the app target.
//
// Replaces `print()` diagnostics across ApexAgentCore with category-tagged,
// level-gated unified-logging entries. Oct-2026 guidance: dynamic content is
// logged `privacy: .private` by default — never mark user content or secrets
// as `.public`. A bounded in-memory ring buffer feeds DiagnosticsView so the
// most recent activity is inspectable in-app without a console.

/// Severity of an `AppLog` entry. Ordered so levels can be compared and gated.
public enum AppLogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case error = 3
    case fault = 4

    public static func < (lhs: AppLogLevel, rhs: AppLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}

/// Subsystem tags for log entries. One case per logging domain so Diagnostics
/// and Console filtering stay useful without one Logger per call site.
public enum AppLogCategory: String, CaseIterable, Sendable {
    case app
    case orchestrator
    case gateway
    case spotlight
    case discord
    case screen
    case voice
    case routine
    case reflection
    case registry
    case toolbox
    case collaboration
    case a2a
    case engine
    case ui
    case audit
    case space
    case project
    case playbook
    case terminal
    case mcp
    case security
    case bot
}

/// One captured log record held by the in-memory ring buffer.
public struct AppLogEntry: Sendable, Equatable {
    public let timestamp: Date
    public let level: AppLogLevel
    public let category: AppLogCategory
    public let message: String

    public init(timestamp: Date, level: AppLogLevel, category: AppLogCategory, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

/// Lock-guarded mutable state for `AppLog`. Encapsulated in a class so Swift's
/// strict-concurrency checker sees only an immutable `static let` reference;
/// every access is serialized by `lock` (`@unchecked Sendable` is justified by
/// that discipline — all stored properties are only touched while holding it).
private final class AppLogStorage: @unchecked Sendable {
    let lock = NSLock()
    var minimumLevel: AppLogLevel = .debug
    var buffer: [AppLogEntry] = []
    var loggers: [AppLogCategory: Logger] = [:]

    static let shared = AppLogStorage()
    private init() {}
}

public enum AppLog {
    /// Subsystem shared with `SharedLogger` so Console.app can aggregate both.
    static let subsystem = "com.apexsuite"

    /// Ring-buffer capacity for DiagnosticsView (oldest entries evicted first).
    public static let bufferCapacity = 500

    private static var storage: AppLogStorage { .shared }

    /// Entries below this level are dropped before they reach unified logging
    /// or the ring buffer. Default `.debug` (record everything).
    public static var minimumLevel: AppLogLevel {
        get {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.minimumLevel
        }
        set {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            storage.minimumLevel = newValue
        }
    }

    /// Most recent entries, newest first. Bounded by `bufferCapacity`.
    public static func recentEntries(limit: Int? = nil) -> [AppLogEntry] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        let newestFirst = storage.buffer.reversed()
        guard let limit else { return Array(newestFirst) }
        return Array(newestFirst.prefix(max(0, limit)))
    }

    /// Clears the ring buffer (DiagnosticsView "Clear" action, tests).
    public static func clearBuffer() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.buffer.removeAll(keepingCapacity: true)
    }

    private static func logger(for category: AppLogCategory) -> Logger {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        if let cached = storage.loggers[category] { return cached }
        let created = Logger(subsystem: subsystem, category: category.rawValue)
        storage.loggers[category] = created
        return created
    }

    // MARK: Logging entry points

    public static func debug(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(level: .debug, category: category, message: message())
    }

    public static func info(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(level: .info, category: category, message: message())
    }

    public static func notice(_ category: AppLogCategory, _ message: @autoclosure () -> String) {
        log(level: .notice, category: category, message: message())
    }

    public static func error(_ category: AppLogCategory, _ message: @autoclosure () -> String,
                             error: Error? = nil) {
        var text = message()
        if let error { text += " — \(error.localizedDescription)" }
        log(level: .error, category: category, message: text)
    }

    public static func fault(_ category: AppLogCategory, _ message: @autoclosure () -> String,
                             error: Error? = nil) {
        var text = message()
        if let error { text += " — \(error.localizedDescription)" }
        log(level: .fault, category: category, message: text)
    }

    /// Single funnel: gate → ring buffer → unified logging.
    static func log(level: AppLogLevel, category: AppLogCategory, message: String) {
        storage.lock.lock()
        guard level >= storage.minimumLevel else {
            storage.lock.unlock()
            return
        }
        storage.buffer.append(AppLogEntry(timestamp: Date(), level: level,
                                          category: category, message: message))
        if storage.buffer.count > bufferCapacity {
            storage.buffer.removeFirst(storage.buffer.count - bufferCapacity)
        }
        storage.lock.unlock()

        // Dynamic content stays private in unified logging (Console redacts it).
        let logger = logger(for: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .private)")
        case .info: logger.info("\(message, privacy: .private)")
        case .notice: logger.notice("\(message, privacy: .private)")
        case .error: logger.error("\(message, privacy: .private)")
        case .fault: logger.fault("\(message, privacy: .private)")
        }
    }
}
