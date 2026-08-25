import Foundation

// MARK: - SecretRedactor: keep secrets out of transcripts, audit logs, and UI (O2, port of OpenMausBot redact.ts)
//
// ApexAgent logs tool arguments and assistant text to transcripts, the audit
// log, and (soon) the decision log. Those artifacts are read by people
// debugging and can be pasted into issues. The redactor keeps the SHAPE and
// drops the VALUE: an entry still tells you a token was passed, under which
// name, and how long it was — enough to debug "the proxy got no token"
// without the token being present anywhere.

/// Masks content-shaped secrets (API keys, JWTs, PEM blocks, Bearer tokens,
/// key=value lines) and credential-shaped map keys (env vars, ACP env entries).
enum SecretRedactor {

    /// `key` alone is too broad — it matches `keyboard`, `keys`, `hotkey`.
    /// Only treat it as a credential when it stands alone or is a suffix, which
    /// is how every real one is spelled (API_KEY, consumer-key, xai_key).
    static func isSecretName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let parts = ["token", "secret", "password", "passwd", "apikey", "api_key", "authorization", "auth_token"]
        guard !parts.contains(where: { lower.contains($0) }) else { return true }
        return lower.range(of: #"(^|[_.-])keys?$"#, options: .regularExpression) != nil
    }

    static func mask(_ value: String) -> String {
        "«redacted \(value.count) chars»"
    }

    // MARK: Content-shaped secrets

    private static let contentPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"\bsk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_-]{16,}"#),  // anthropic / openai / stripe
        try! NSRegularExpression(pattern: #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#),        // github classic
        try! NSRegularExpression(pattern: #"\bgithub_pat_[A-Za-z0-9_]{20,}"#),                     // github fine-grained
        try! NSRegularExpression(pattern: #"\bxox[abposr]-[A-Za-z0-9-]{20,}"#),                    // slack
        try! NSRegularExpression(pattern: #"\bAKIA[0-9A-Z]{16}\b"#),                              // aws access key id
        try! NSRegularExpression(pattern: #"\bAIza[0-9A-Za-z_-]{30,}"#),                           // google api key
        try! NSRegularExpression(pattern: #"\bnpm_[A-Za-z0-9]{20,}"#),                             // npm
        try! NSRegularExpression(pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#), // jwt
    ]

    private static let bearerPattern =
        try! NSRegularExpression(pattern: #"(\bBearer\s+)([A-Za-z0-9._~+/=-]{12,})"#, options: [.caseInsensitive])

    private static let pemPattern = try! NSRegularExpression(
        pattern: #"(-----BEGIN [A-Z ]*PRIVATE KEY-----)([\s\S]*?)(-----END [A-Z ]*PRIVATE KEY-----)"#)

    /// key=value / key: value / key="value" where the key is secret-shaped.
    private static let keyValuePattern = try! NSRegularExpression(
        pattern: #"\b((?:[A-Za-z0-9_-]*_)?(?:api[_-]?key|apikey|secret|token|password|passwd|authorization|auth[_-]?token|access[_-]?key|private[_-]?key)s?)(["']?\s*[=:]\s*)(["']?)([A-Za-z0-9._~+/=-]{8,})\3"#,
        options: [.caseInsensitive])

    // MARK: Public API

    /// Replace every match using values computed in code (never regex
    /// templates — `$0`/`$N` would echo the secret back inside its own mask).
    private static func replaceAll(
        _ text: String,
        pattern: NSRegularExpression,
        transform: (_ groups: [String]) -> String
    ) -> String {
        let nsText = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = text as NSString
        // Reverse order so earlier ranges stay valid while we mutate.
        for match in matches.reversed() {
            let groups = (0..<match.numberOfRanges).map { idx -> String in
                let range = match.range(at: idx)
                return range.location == NSNotFound ? "" : result.substring(with: range)
            }
            result = result.replacingCharacters(in: match.range, with: transform(groups)) as NSString
        }
        return result as String
    }

    /// Redact every credential-looking value inside free text (a transcript
    /// line, a tool summary, an error). Short strings are skipped as a cheap
    /// guard against rewriting normal prose.
    static func redact(text: String) -> String {
        guard text.count >= 8 else { return text }
        var out = text

        // PEM blocks first: open / body / close, keeping shape, masking body.
        out = replaceAll(out, pattern: pemPattern) { groups in
            "\(groups[1])\n\(mask(groups[2].trimmingCharacters(in: .whitespacesAndNewlines)))\n\(groups[3])"
        }

        // Content-shaped keys: whole match is the secret.
        for pattern in contentPatterns {
            out = replaceAll(out, pattern: pattern) { groups in
                mask(groups[0])
            }
        }

        // Bearer tokens: keep the scheme, drop the token.
        out = replaceAll(out, pattern: bearerPattern) { groups in
            "\(groups[1])\(mask(groups[2]))"
        }

        // key=value / key="value": keep the name and quoting, drop the value.
        out = replaceAll(out, pattern: keyValuePattern) { groups in
            "\(groups[1])\(groups[2])\(groups[3])\(mask(groups[4]))\(groups[3])"
        }

        return out
    }

    /// Redact a dictionary of environment-style variables, masking values whose
    /// keys are credential-shaped (e.g. `{ "ANTHROPIC_API_KEY": "…" }`).
    static func redactEnvironment(_ env: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in env {
            if isSecretName(key) {
                out[key] = mask(value)
            } else {
                out[key] = redact(text: value)
            }
        }
        return out
    }
}