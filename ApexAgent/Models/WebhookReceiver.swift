import Foundation

// MARK: - Webhooks: external triggers for .webhook routines (O5, port of OpenMausBot webhook-ingress.ts)
//
// A routine with trigger == .webhook can be fired by an external POST to
// /hooks/<endpointId>. The HTTP plumbing stays thin: this file owns the whole
// decision surface (path matching, secret authorization, body cap, payload
// parsing, delivery dedupe) as pure functions over a `WebhookDelivery`, so it
// is fully unit-testable without opening a socket. A future NWListener server
// only has to translate bytes → WebhookDelivery and status back out.

struct WebhookEndpoint: Equatable, Codable, Sendable {
    /// Public path id, "wh_" + url-safe random suffix.
    let id: String
    /// Bearer/path secret shown once at creation.
    let secret: String
    /// The Routine (by name) this endpoint fires.
    var targetRoutineName: String
    var enabled: Bool = true
}

enum WebhookPayload: Equatable {
    case json([String: String])
    case form([String: String])
    case text(String)
    case empty
}

/// One inbound webhook request, transport-agnostic.
struct WebhookDelivery {
    var method: String = "POST"
    var path: String
    var authorizationHeader: String?
    /// Fallback secret header (x-apex-secret), mirroring OpenMausBot's x-openmaus-secret.
    var secretHeader: String?
    var contentType: String?
    var rawBody: String?
    /// Body size as streamed so the byte cap can be enforced before parsing.
    var bodySize: Int
    var eventName: String?
    var deliveryId: String?
}

enum WebhookReceiveOutcome: Equatable {
    case accepted(routineName: String, deliveryId: String?, duplicate: Bool)
    case rejected(status: Int, reason: String)

    var statusCode: Int {
        switch self {
        case .accepted: return 202
        case .rejected(let status, _): return status
        }
    }
}

final class WebhookManager: @unchecked Sendable {
    static let shared = WebhookManager()

    private let lock = NSLock()
    private var endpoints: [String: WebhookEndpoint] = [:]
    private var seenDeliveries: [String] = []   // bounded recent delivery ids per process

    static let maxBodyBytes = 256 * 1024
    private let maxTrackedDeliveries = 128

    // MARK: Endpoint CRUD

    @discardableResult
    func addEndpoint(targetRoutineName: String) -> WebhookEndpoint {
        lock.lock()
        defer { lock.unlock() }
        let endpoint = WebhookEndpoint(
            id: Self.newEndpointId(),
            secret: Self.newSecret(),
            targetRoutineName: targetRoutineName,
            enabled: true)
        endpoints[endpoint.id] = endpoint
        return endpoint
    }

    func removeEndpoint(id: String) {
        lock.lock()
        defer { lock.unlock() }
        endpoints.removeValue(forKey: id)
    }

    func setEnabled(id: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        endpoints[id]?.enabled = enabled
    }

    func endpoint(id: String) -> WebhookEndpoint? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[id]
    }

    var allEndpoints: [WebhookEndpoint] {
        lock.lock()
        defer { lock.unlock() }
        return Array(endpoints.values).sorted { $0.id < $1.id }
    }

    // MARK: Authorization

    func authorize(id: String, secret: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let endpoint = endpoints[id], endpoint.enabled else { return false }
        return endpoint.secret == secret
    }

    /// Credential bundle for senders: endpoint URL, bearer secret, and the
    /// single capability URL that carries the secret in the path.
    func credential(baseUrl: String, endpointId: String) -> (url: String, secret: String, capabilityURL: String)? {
        guard let endpoint = endpoint(id: endpointId) else { return nil }
        let base = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
        let endpointUrl = "\(base)/hooks/\(endpoint.id)"
        return (endpointUrl, endpoint.secret, "\(endpointUrl)/\(endpoint.secret)")
    }

    // MARK: Delivery bookkeeping

    /// True if this deliveryId was already accepted for the endpoint. Also
    /// records the id when new (call before triggering).
    func isDuplicate(endpointId: String, deliveryId: String?) -> Bool {
        guard let deliveryId, !deliveryId.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let key = "\(endpointId)#\(deliveryId)"
        if seenDeliveries.contains(key) { return true }
        seenDeliveries.append(key)
        if seenDeliveries.count > maxTrackedDeliveries {
            seenDeliveries.removeFirst(seenDeliveries.count - maxTrackedDeliveries)
        }
        return false
    }

    // MARK: Ids / secrets

    static func newEndpointId() -> String {
        "wh_" + Self.urlSafeToken(length: 20)
    }

    static func newSecret() -> String {
        Self.urlSafeToken(length: 32)
    }

    private static func urlSafeToken(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

// MARK: - Router (pure request → outcome)

enum WebhookRouter {

    /// Route one delivery. On success calls `onTrigger` with the endpoint and
    /// parsed payload; never throws — every failure is a status + reason.
    static func route(
        manager: WebhookManager,
        request: WebhookDelivery,
        onTrigger: (_ endpoint: WebhookEndpoint, _ payload: WebhookPayload, _ eventName: String?, _ deliveryId: String?) -> Void = { _, _, _, _ in }
    ) -> WebhookReceiveOutcome {
        // Health probe needs no auth.
        if request.method == "GET" && request.path == "/health" {
            return .accepted(routineName: "__health__", deliveryId: nil, duplicate: false)
        }

        guard let match = parseEndpointPath(request.path) else {
            return .rejected(status: 404, reason: "Unknown webhook endpoint")
        }
        guard request.method.uppercased() == "POST" else {
            return .rejected(status: 405, reason: "Webhooks accept POST requests")
        }

        // Reject bad capability URLs before parsing attacker input.
        let secret = resolvedSecret(request, pathSecret: match.pathSecret)
        guard manager.authorize(id: match.id, secret: secret) else {
            return .rejected(status: 401, reason: "Invalid webhook URL or secret")
        }
        guard let endpoint = manager.endpoint(id: match.id) else {
            return .rejected(status: 404, reason: "Unknown webhook endpoint")
        }
        guard request.bodySize <= WebhookManager.maxBodyBytes else {
            return .rejected(status: 413, reason: "Webhook body is too large")
        }

        let payload = parsePayload(raw: request.rawBody, contentType: request.contentType)
        if case .rejectedStatus(let status, let reason) = payload {
            return .rejected(status: status, reason: reason)
        }

        let deliveryId = normalizedDeliveryId(request)
        let duplicate = manager.isDuplicate(endpointId: match.id, deliveryId: deliveryId)
        if !duplicate {
            onTrigger(endpoint, payloadValue(payload), request.eventName, deliveryId)
        }
        return .accepted(routineName: endpoint.targetRoutineName, deliveryId: deliveryId, duplicate: duplicate)
    }

    enum PayloadParseResult {
        case value(WebhookPayload)
        case rejectedStatus(status: Int, reason: String)
    }

    static func parseEndpointPath(_ path: String) -> (id: String, pathSecret: String?)? {
        guard let regex = try? NSRegularExpression(pattern: #"^/hooks/(wh_[A-Za-z0-9_-]+)(?:/(.+))?$"#) else { return nil }
        let nsPath = path as NSString
        guard let match = regex.firstMatch(in: path, range: NSRange(location: 0, length: nsPath.length)) else { return nil }
        func group(_ idx: Int) -> String? {
            let r = match.range(at: idx)
            guard r.location != NSNotFound else { return nil }
            return nsPath.substring(with: r)
        }
        guard let id = group(1) else { return nil }
        return (id, group(2))
    }

    static func parsePayload(raw: String?, contentType: String?) -> PayloadParseResult {
        guard let raw, !raw.isEmpty else { return .value(.empty) }
        let type = contentType?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "text/plain"

        if type == "application/json" || type.hasSuffix("+json") {
            guard let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                return .rejectedStatus(status: 400, reason: "Invalid JSON webhook body")
            }
            var flat: [String: String] = [:]
            for (key, value) in dict {
                switch value {
                case let s as String: flat[key] = s
                case let n as NSNumber: flat[key] = n.stringValue
                default: flat[key] = String(describing: value)
                }
            }
            return .value(.json(flat))
        }
        if type == "application/x-www-form-urlencoded" {
            var flat: [String: String] = [:]
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding else { continue }
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
                flat[key] = value
            }
            return .value(.form(flat))
        }
        return .value(.text(raw))
    }

    private static func payloadValue(_ result: PayloadParseResult) -> WebhookPayload {
        if case .value(let payload) = result { return payload }
        return .empty
    }

    private static func normalizedDeliveryId(_ request: WebhookDelivery) -> String? {
        guard let id = request.deliveryId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return id
    }

    /// Path segment wins when present (capability URLs); otherwise Bearer,
    /// then the dedicated fallback header.
    private static func resolvedSecret(_ request: WebhookDelivery, pathSecret: String?) -> String {
        if let pathSecret, !pathSecret.isEmpty {
            return pathSecret.removingPercentEncoding ?? pathSecret
        }
        return bearerSecret(request)
    }

    static func bearerSecret(_ request: WebhookDelivery) -> String {
        if let auth = request.authorizationHeader,
           auth.range(of: #"^Bearer\s+\S+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let parts = auth.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            if parts.count > 1 {
                let candidate = parts[1].trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty { return candidate }
            }
        }
        return request.secretHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }


}

extension WebhookManager {
    // MARK: - Markdown Endpoints Export

    func formatWebhookEndpointsMarkdown() -> String {
        let eps = allEndpoints
        guard !eps.isEmpty else {
            return "No inbound webhook ingress endpoints registered."
        }

        var md = "### 🪝 Inbound Webhook Ingress Endpoints (\(eps.count) configured)\n\n"
        md += "| Endpoint ID | Target Routine | Status | Secret Redacted |\n"
        md += "|---|---|---|---|\n"

        for ep in eps {
            let status = ep.enabled ? "🟢 Enabled" : "⚪️ Disabled"
            let redacted = String(ep.secret.prefix(4)) + "••••••••"
            let safeTarget = ep.targetRoutineName.replacingOccurrences(of: "|", with: "\\|")
            md += "| `\(ep.id)` | `\(safeTarget)` | \(status) | `\(redacted)` |\n"
        }
        return md
    }
}
