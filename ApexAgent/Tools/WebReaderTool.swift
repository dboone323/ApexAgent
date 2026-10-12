//
//  WebReaderTool.swift
//  ApexAgent
//
//  Created for Batch 105: WebReaderTool, WebContentSanitizer & SSRF Guard.
//

import Foundation
import FoundationModels

// MARK: - Web Reader Configuration

public struct WebReaderConfiguration: Sendable, Codable, Equatable {
    public var maxByteLimit: Int
    public var maxExtractedLength: Int
    public var disallowPrivateIPs: Bool
    public var disallowCloudMetadata: Bool
    public var allowedSchemes: Set<String>
    public var stripScriptsAndStyles: Bool
    public var detectPromptInjections: Bool

    public init(
        maxByteLimit: Int = 1_500_000,
        maxExtractedLength: Int = 40_000,
        disallowPrivateIPs: Bool = true,
        disallowCloudMetadata: Bool = true,
        allowedSchemes: Set<String> = ["http", "https"],
        stripScriptsAndStyles: Bool = true,
        detectPromptInjections: Bool = true
    ) {
        self.maxByteLimit = maxByteLimit
        self.maxExtractedLength = maxExtractedLength
        self.disallowPrivateIPs = disallowPrivateIPs
        self.disallowCloudMetadata = disallowCloudMetadata
        self.allowedSchemes = allowedSchemes
        self.stripScriptsAndStyles = stripScriptsAndStyles
        self.detectPromptInjections = detectPromptInjections
    }
}

// MARK: - SSRF Guard

public struct SSRFGuard: Sendable {
    private static let metadataHosts: Set<String> = [
        "169.254.169.254",
        "metadata.google.internal",
        "metadata.azure.internal",
        "instance-data"
    ]

    public static func validate(url: URL, config: WebReaderConfiguration) -> (allowed: Bool, reason: String?) {
        guard let scheme = url.scheme?.lowercased(), config.allowedSchemes.contains(scheme) else {
            return (false, "Scheme '\(url.scheme ?? "")' is not in allowed schemes \(config.allowedSchemes)")
        }

        guard let host = url.host?.lowercased() else {
            return (false, "URL is missing host component")
        }

        if config.disallowCloudMetadata && metadataHosts.contains(host) {
            return (false, "Access to cloud instance metadata service '\(host)' is strictly prohibited")
        }

        if config.disallowPrivateIPs {
            if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
                return (false, "Loopback addresses (\(host)) are blocked")
            }
            if host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") {
                return (false, "Private subnet IP (\(host)) is blocked")
            }
            // 172.16.0.0 - 172.31.255.255
            if host.hasPrefix("172.") {
                let parts = host.split(separator: ".")
                if parts.count >= 2, let second = Int(parts[1]), second >= 16 && second <= 31 {
                    return (false, "Private RFC1918 subnet IP (\(host)) is blocked")
                }
            }
        }

        return (true, nil)
    }
}

// MARK: - Web Content Sanitizer & HTML to Markdown Converter

public struct WebContentSanitizer: Sendable {
    public static func sanitizeHTMLToMarkdown(_ html: String, maxExtractedLength: Int = 40_000) -> String {
        var text = html

        // 1. Strip script, style, noscript, svg, canvas, iframe blocks
        let dangerousTags = ["script", "style", "noscript", "svg", "canvas", "iframe"]
        for tag in dangerousTags {
            let pattern = "(?is)<\(tag)[^>]*>.*?</\(tag)>"
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        // 2. Strip elements with inline hidden styles (common prompt injection vector)
        let hiddenPattern = "(?is)<[^>]+style=[\"'][^\"']*(display:\\s*none|visibility:\\s*hidden|opacity:\\s*0)[^\"']*[\"'][^>]*>.*?</[^>]+>"
        text = text.replacingOccurrences(of: hiddenPattern, with: "", options: .regularExpression)

        // 3. Convert headers
        for level in (1...6).reversed() {
            let hashes = String(repeating: "#", count: level)
            let headerPattern = "(?is)<h\(level)[^>]*>(.*?)</h\(level)>"
            text = text.replacingOccurrences(of: headerPattern, with: "\n\n\(hashes) $1\n\n", options: .regularExpression)
        }

        // 4. Convert links: <a href="url">text</a> -> [text](url)
        let linkPattern = "(?is)<a[^>]+href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"
        text = text.replacingOccurrences(of: linkPattern, with: "[$2]($1)", options: .regularExpression)

        // 5. Convert lists
        text = text.replacingOccurrences(of: "(?is)<li[^>]*>(.*?)</li>", with: "\n* $1", options: .regularExpression)

        // 6. Convert paragraphs and line breaks
        text = text.replacingOccurrences(of: "(?is)<p[^>]*>(.*?)</p>", with: "\n\n$1\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?is)<hr\\s*/?>", with: "\n---\n", options: .regularExpression)

        // 7. Strip any remaining HTML tags
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // 8. Decode HTML entities
        text = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")

        // 9. Normalize multiple newlines and spaces
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 10. Truncation
        if text.count > maxExtractedLength {
            let truncated = String(text.prefix(maxExtractedLength))
            return truncated + "\n\n[... Content truncated at \(maxExtractedLength) characters ...]"
        }

        return text
    }
}

// MARK: - Prompt Injection & Web Security Auditor

public struct WebReaderViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct WebReaderAuditReport: Sendable, Codable, Equatable {
    public let targetURL: String
    public let isAllowed: Bool
    public let ssrfSafe: Bool
    public let promptInjectionDetected: Bool
    public let sanitizedLength: Int
    public let violations: [WebReaderViolation]
    public let securityScore: Double
}

public struct WebReaderSecurityAuditor: Sendable {
    private static let injectionSignatures = [
        "ignore previous instructions",
        "ignore all previous instructions",
        "system prompt override",
        "disregard instructions",
        "you are now in developer mode",
        "dan mode",
        "jailbreak enabled"
    ]

    public static func audit(
        url: URL,
        rawContent: String,
        config: WebReaderConfiguration
    ) -> WebReaderAuditReport {
        var violations: [WebReaderViolation] = []
        let (ssrfAllowed, ssrfReason) = SSRFGuard.validate(url: url, config: config)

        if !ssrfAllowed {
            violations.append(WebReaderViolation(
                code: "SSRF_VIOLATION",
                message: ssrfReason ?? "Blocked by SSRF Guard",
                isFatal: true
            ))
        }

        var injectionDetected = false
        if config.detectPromptInjections {
            let lowerContent = rawContent.lowercased()
            for sig in injectionSignatures {
                if lowerContent.contains(sig) {
                    injectionDetected = true
                    violations.append(WebReaderViolation(
                        code: "PROMPT_INJECTION_DETECTED",
                        message: "Content contains prompt-override pattern: '\(sig)'",
                        isFatal: false
                    ))
                    break
                }
            }
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let warnCount = violations.filter { !$0.isFatal }.count
        let rawScore = 1.0 - (Double(fatalCount) * 0.5) - (Double(warnCount) * 0.2)
        let score = max(0.0, min(1.0, rawScore))
        let allowed = fatalCount == 0

        return WebReaderAuditReport(
            targetURL: url.absoluteString,
            isAllowed: allowed,
            ssrfSafe: ssrfAllowed,
            promptInjectionDetected: injectionDetected,
            sanitizedLength: rawContent.count,
            violations: violations,
            securityScore: score
        )
    }

    public static func formatWebReaderReportMarkdown(_ report: WebReaderAuditReport) -> String {
        var md = "### 🌐 Web Reader Security & Sanitization Audit\n\n"
        md += "| Parameter | Value | Status |\n"
        md += "|---|---|---|\n"
        md += "| Target URL | `\(report.targetURL)` | \(report.ssrfSafe ? "✅ Allowed" : "❌ Blocked") |\n"
        md += "| SSRF Guard | \(report.ssrfSafe ? "🛡️ Passed" : "🔴 Blocked Private Host") | Network Perimeter |\n"
        md += "| Prompt Injection | \(report.promptInjectionDetected ? "⚠️ Potential Risk Flagged" : "✅ Clean") | Adversarial Check |\n"
        md += "| Extracted Length | `\(report.sanitizedLength)` chars | Context Budget |\n"
        md += "| Security Score | `\(Int(report.securityScore * 100))%` | \(report.securityScore >= 0.8 ? "🛡️ Safe" : "⚠️ Caution") |\n\n"

        if !report.violations.isEmpty {
            md += "#### Findings\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 **[FATAL]**" : "🟡 **[WARN]**"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}

// MARK: - Web Reader Tool

public struct WebReaderTool: Tool {
    let orchestrator: OrchestratorProvider?
    public let configuration: WebReaderConfiguration

    public init(configuration: WebReaderConfiguration = WebReaderConfiguration()) {
        self.orchestrator = nil
        self.configuration = configuration
    }

    init(orchestrator: OrchestratorProvider?, configuration: WebReaderConfiguration = WebReaderConfiguration()) {
        self.orchestrator = orchestrator
        self.configuration = configuration
    }

    public let name = "web_reader"
    public let description = """
    Reads content from a public web page, returning sanitized, clean Markdown text. \
    Enforces SSRF perimeter checks, strips scripts/styles/hidden injection vectors, \
    and caps response size for safe LLM context ingestion.
    """

    @Generable
    public struct Arguments: Decodable {
        @Guide(description: "The HTTP/HTTPS URL of the web page to read")
        public var url: String

        @Guide(description: "Optional maximum characters to extract (default 40,000)")
        public var maxLength: Int?

        public init(url: String, maxLength: Int? = nil) {
            self.url = url
            self.maxLength = maxLength
        }
    }

    public func call(arguments: Arguments) async throws -> String {
        guard let url = URL(string: arguments.url) else {
            return "Error: Invalid URL '\(arguments.url)'"
        }

        let (allowed, reason) = SSRFGuard.validate(url: url, config: configuration)
        guard allowed else {
            return "Security Error: URL was rejected by SSRF perimeter gate: \(reason ?? "Blocked")"
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("text/html,application/xhtml+xml,text/plain;q=0.9", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 20.0

        let session = URLSession.shared
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            return "Error: Did not receive a valid HTTP response."
        }

        guard httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 else {
            return "Error: Server returned HTTP status \(httpResponse.statusCode)."
        }

        guard let rawHTML = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return "Error: Unable to decode web page content as UTF-8 or ASCII."
        }

        let targetCap = arguments.maxLength ?? configuration.maxExtractedLength
        let markdown = WebContentSanitizer.sanitizeHTMLToMarkdown(rawHTML, maxExtractedLength: targetCap)

        let audit = WebReaderSecurityAuditor.audit(url: url, rawContent: markdown, config: configuration)
        var responsePrefix = ""
        if audit.promptInjectionDetected {
            responsePrefix = "⚠️ [WARNING: Potential Prompt Injection detected in page content]\n\n"
        }

        return responsePrefix + markdown
    }
}
