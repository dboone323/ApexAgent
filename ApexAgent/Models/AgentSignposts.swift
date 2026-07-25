import Foundation
import os
import os.signpost

// MARK: - Agent Signposts & Structured Logging (Instruments)
//
// Performance signposts + structured OSLog categories so Instruments (the
// Foundation Models template + Time Profiler) captures meaningful spans for
// each agent phase and tool call — WWDC26 "Debug and profile agentic app
// experiences with Instruments". Categories: Agent, Tools, Security, Provider.

let agentSignpostLog = OSLog(subsystem: "com.apexagent.app", category: "AgentPerformance")
/// Points-of-Interest log: renders in Instruments' Time Profiler "Points of Interest"
/// lane automatically (no manual os_signpost instrument needed). Used to mark
/// generation boundaries so a profile always shows *something* even if the
/// dedicated os_signpost instrument isn't added.
let agentPointsOfInterestLog = OSLog(subsystem: "com.apexagent.app", category: "points-of-interest")

extension Logger {
    static let agent    = Logger(subsystem: "com.apexagent.app", category: "Agent")
    static let tools    = Logger(subsystem: "com.apexagent.app", category: "Tools")
    static let security = Logger(subsystem: "com.apexagent.app", category: "Security")
    static let provider = Logger(subsystem: "com.apexagent.app", category: "Provider")
}

/// Lightweight helper that brackets a span with os_signpost begin/end so agent
/// phases and tool executions show up as intervals in Instruments.
enum AgentSignpost {

    /// Begin a named span; returns the signpost ID to pass to `end`.
    static func begin(_ name: StaticString, detail: String = "") -> OSSignpostID {
        let id = OSSignpostID(log: agentSignpostLog)
        os_signpost(.begin, log: agentSignpostLog, name: name, signpostID: id, "%{public}s", detail)
        return id
    }

    static func end(_ name: StaticString, _ id: OSSignpostID, detail: String = "") {
        os_signpost(.end, log: agentSignpostLog, name: name, signpostID: id, "%{public}s", detail)
    }

    /// Emit a single-point (event) signpost — no duration span.
    static func event(_ name: StaticString, detail: String = "") {
        os_signpost(.event, log: agentSignpostLog, name: name, "%{public}s", detail)
    }

    /// Convenience: run an async body inside a signposted span. Inherits the
    /// caller's actor isolation (#isolation) so non-Sendable closures from
    /// @MainActor contexts don't cross an isolation boundary (Swift 6).
    static func span<T>(
        _ name: StaticString,
        detail: String = "",
        isolation: isolated (any Actor)? = #isolation,
        body: () async throws -> T
    ) async rethrows -> T {
        let id = begin(name, detail: detail)
        defer { end(name, id) }
        return try await body()
    }
}
