import Foundation
import os

/// Unified tracing span API.
///
/// A single `Tracing.span()` call records the operation three ways so the same
/// event is visible everywhere it should be:
///   1. **Instruments** — an `os_signpost` interval (AgentPerformance category),
///      so Time Profiler / the Foundation Models template show real spans.
///   2. **System log** — a structured `Logger` line (com.apexagent.app/Tracing).
///   3. **In-app trace buffer** — a `TraceEvent` appended to `TraceBus`,
///      which backs the `/api/traces` debug endpoint and the dashboard.
///
/// Built on the existing `AgentSignpost` + `TraceBus`/`TraceEvent` primitives;
/// this is the thin coordinator WS4 calls for. Mirrors `AgentSignpost.span`'s
/// `#isolation` capture so non-Sendable closures from `@MainActor` contexts
/// don't cross an isolation boundary (Swift 6 concurrency).
enum Tracing {
    private static let log = Logger(subsystem: "com.apexagent.app", category: "Tracing")

    /// Run `body` inside a traced span and record its duration to the trace bus.
    /// - Parameters:
    ///   - name: operation name (e.g. "mcp.request", "orchestrator.run").
    ///   - source: subsystem emitting the span (e.g. "MCPClient", "Orchestrator").
    ///   - metadata: optional key/value pairs attached to the `TraceEvent`.
    @discardableResult
    static func span<T>(
        _ name: StaticString,
        source: String,
        metadata: [String: String]? = nil,
        isolation: isolated (any Actor)? = #isolation,
        body: () async throws -> T
    ) async rethrows -> T {
        let signpostID = AgentSignpost.begin(name)
        let start = ContinuousClock().now
        defer {
            let duration = ContinuousClock().now - start
            AgentSignpost.end(name, signpostID)
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000 + Double(duration.components.seconds) * 1000
            log.info("\(source).\(String(describing: name)) completed in \(String(format: "%.1f", ms))ms")
            TraceBus.shared.append(TraceEvent(
                source: source,
                operation: String(describing: name),
                durationMs: ms,
                metadata: metadata
            ))
        }
        return try await body()
    }

    /// Emit a single-point trace event (no duration span).
    static func event(_ operation: String, source: String, detail: String = "", metadata: [String: String]? = nil) {
        log.info("\(source).\(operation) \(detail)")
        TraceBus.shared.append(TraceEvent(
            source: source,
            operation: operation,
            detail: detail,
            metadata: metadata
        ))
    }

    /// Recent spans from the in-app trace buffer (backs `/api/traces`).
    static func recentTraces(limit: Int = 50) -> [TraceEvent] {
        TraceBus.shared.recentEvents(limit: limit)
    }
}
