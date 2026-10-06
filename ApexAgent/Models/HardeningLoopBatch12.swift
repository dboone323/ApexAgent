import Foundation

// MARK: - Hardening Loop Batch 12: Input Validation & Logic Hardening
//
// 10 additive defensive fixes. Each is a new dedicated validation method or
// guard — no changes to existing call sites or behavior.

extension MCPServerConfig {
    /// Validates a server config before persistence/use. Returns nil when valid.
    public func validationError() -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty { return "Server name must not be empty." }
        let trimmedCmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCmd.isEmpty { return "Server command must not be empty." }
        if transport != "stdio" && transport != "http" && transport != "sse" {
            return "Unsupported transport '\(transport)'. Expected stdio, http, or sse."
        }
        if (transport == "http" || transport == "sse") {
            guard let url = endpointURL, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Transport '\(transport)' requires a non-empty endpointURL."
            }
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
                return "endpointURL must start with http:// or https://."
            }
        }
        return nil
    }

    public var isValid: Bool { validationError() == nil }
}

extension MCPClientConfig {
    /// Clamps out-of-range tunables to sane bounds. Returns clamped copy.
    public func clamped() -> MCPClientConfig {
        var c = self
        c.requestTimeout = min(max(c.requestTimeout, 1), 600)
        c.pingTimeout = min(max(c.pingTimeout, 0.5), 60)
        c.maxRetries = min(max(c.maxRetries, 0), 20)
        c.circuitFailureThreshold = min(max(c.circuitFailureThreshold, 1), 20)
        c.restartRateLimitWindow = min(max(c.restartRateLimitWindow, 5), 3600)
        c.maxRestartsInWindow = min(max(c.maxRestartsInWindow, 1), 50)
        return c
    }
}

extension DimensionScore {
    /// Guards against inverted pass/total counts before scoring.
    public static func validated(dimension: AgentEvaluationDimension, passedChecks: Int, totalChecks: Int, notes: String = "") -> DimensionScore {
        let safeTotal = max(totalChecks, 0)
        let safePassed = min(max(passedChecks, 0), safeTotal)
        return DimensionScore(dimension: dimension, passedChecks: safePassed, totalChecks: safeTotal, notes: notes)
    }
}

extension CronSchedule {
    /// Safe constructor returning nil instead of throwing.
    public static func validated(expression: String) -> CronSchedule? {
        try? CronSchedule(expression: expression)
    }

    /// Human summary for invalid input without throwing.
    public static func validationMessage(for expression: String) -> String {
        if (try? CronSchedule(expression: expression)) != nil {
            return "Valid cron expression."
        }
        return "Invalid cron expression: '\(expression)'. Expected 5 fields (minute hour day month weekday)."
    }
}

extension WebhookManager {
    /// Validates an endpoint id shape before lookup (avoids lock churn on junk).
    public static func isPlausibleEndpointId(_ id: String) -> Bool {
        guard id.hasPrefix("wh_") else { return false }
        let suffix = id.dropFirst(3)
        guard suffix.count >= 8 && suffix.count <= 64 else { return false }
        return suffix.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// Authorize with id-shape pre-check (same semantics, early reject).
    public func authorizeValidated(id: String, secret: String) -> Bool {
        guard Self.isPlausibleEndpointId(id), !secret.isEmpty else { return false }
        return authorize(id: id, secret: secret)
    }
}

extension A2APeerDiscovery {
    /// Pure duplicate filter: removes exact-duplicate endpoints from any peer
    /// list, keeping the most recent record per endpoint. The caller owns
    /// mutation (`discoveredPeers` is `private(set)`); use with `clearPeers()`
    /// + re-add, or on a snapshot copy.
    public static func deduplicatedPeers(_ peers: [DiscoveredPeer]) -> [DiscoveredPeer] {
        var seen: Set<String> = []
        var unique: [DiscoveredPeer] = []
        for peer in peers.sorted(by: { $0.discoveredAt > $1.discoveredAt }) {
            let key = "\(peer.endpoint)"
            if seen.insert(key).inserted {
                unique.append(peer)
            }
        }
        return unique.sorted(by: { $0.discoveredAt < $1.discoveredAt })
    }
}

extension WebhookDelivery {
    /// Pre-parse sanity: method/path/body-size checks. Nil = OK.
    public func preflightError() -> String? {
        if method != "POST" && method != "GET" { return "Unsupported method '\(method)'." }
        if !path.hasPrefix("/hooks/") && path != "/health" { return "Unknown path." }
        if bodySize < 0 { return "Negative body size." }
        if bodySize > WebhookManager.maxBodyBytes { return "Body exceeds 256 KiB cap." }
        return nil
    }
}
