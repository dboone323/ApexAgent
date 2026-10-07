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

/// W3C Trace Context (`traceparent`) generator and validator for MCP `_meta` propagation
/// and `TraceBus` span correlation (MCP `2026-07-28` specification).
public struct W3CTraceContext: Codable, Sendable, Equatable {
    public let version: String
    public let traceId: String
    public let spanId: String
    public let traceFlags: String

    public init(
        version: String = "00",
        traceId: String,
        spanId: String,
        traceFlags: String = "01"
    ) {
        self.version = version.lowercased()
        self.traceId = traceId.lowercased()
        self.spanId = spanId.lowercased()
        self.traceFlags = traceFlags.lowercased()
    }

    public var traceparent: String {
        "\(version)-\(traceId)-\(spanId)-\(traceFlags)"
    }

    public var isSampled: Bool {
        guard let flagsByte = UInt8(traceFlags, radix: 16) else { return false }
        return (flagsByte & 0x01) != 0
    }

    public var metaDictionary: [String: String] {
        ["traceparent": traceparent]
    }

    public static func generate(sampled: Bool = true) -> W3CTraceContext {
        let traceUUID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanRaw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let spanId = String(spanRaw.prefix(16))
        return W3CTraceContext(
            version: "00",
            traceId: traceUUID,
            spanId: spanId,
            traceFlags: sampled ? "01" : "00"
        )
    }

    public static func parse(_ traceparent: String) -> W3CTraceContext? {
        guard isValidTraceparent(traceparent) else { return nil }
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return nil }
        return W3CTraceContext(
            version: parts[0],
            traceId: parts[1],
            spanId: parts[2],
            traceFlags: parts[3]
        )
    }

    public static func isValidTraceparent(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return false }
        let version = parts[0]
        let traceId = parts[1]
        let spanId = parts[2]
        let flags = parts[3]

        guard version.count == 2, version != "ff", isLowercaseHex(version) else { return false }
        guard traceId.count == 32, traceId != String(repeating: "0", count: 32), isLowercaseHex(traceId) else { return false }
        guard spanId.count == 16, spanId != String(repeating: "0", count: 16), isLowercaseHex(spanId) else { return false }
        guard flags.count == 2, isLowercaseHex(flags) else { return false }
        return true
    }

    private static func isLowercaseHex(_ string: String) -> Bool {
        for scalar in string.unicodeScalars {
            let v = scalar.value
            let isDigit = (v >= 0x30 && v <= 0x39)
            let isLowerHex = (v >= 0x61 && v <= 0x66)
            if !isDigit && !isLowerHex {
                return false
            }
        }
        return !string.isEmpty
    }
}

