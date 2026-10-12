//
//  OAuthPKCEAuditor.swift
//  ApexAgent
//
//  Created for Batch 119: OAuth 2.0 PKCE (RFC 7636) Authorization & Token Refresh Auditor.
//

import Foundation
import CryptoKit

// MARK: - PKCE Pair Model

public struct PKCEPair: Sendable, Codable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method: String // Must be "S256"

    public init(verifier: String, challenge: String, method: String = "S256") {
        self.verifier = verifier
        self.challenge = challenge
        self.method = method
    }
}

// MARK: - OAuth Authorization Config & Models

public struct OAuthAuthorizationURLConfig: Sendable, Codable, Equatable {
    public let authorizationEndpoint: URL
    public let clientId: String
    public let redirectURI: URL
    public let scopes: [String]
    public let state: String
    public let pkce: PKCEPair

    public init(
        authorizationEndpoint: URL,
        clientId: String,
        redirectURI: URL,
        scopes: [String],
        state: String,
        pkce: PKCEPair
    ) {
        self.authorizationEndpoint = authorizationEndpoint
        self.clientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.state = state
        self.pkce = pkce
    }
}

public struct OAuthAuditViolation: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let isFatal: Bool

    public init(code: String, message: String, isFatal: Bool = true) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

public struct OAuthAuditReport: Sendable, Codable, Equatable {
    public let passed: Bool
    public let score: Double
    public let challengeMethod: String
    public let isPKCEVerified: Bool
    public let violations: [OAuthAuditViolation]

    public init(
        passed: Bool,
        score: Double,
        challengeMethod: String,
        isPKCEVerified: Bool,
        violations: [OAuthAuditViolation]
    ) {
        self.passed = passed
        self.score = score
        self.challengeMethod = challengeMethod
        self.isPKCEVerified = isPKCEVerified
        self.violations = violations
    }
}

// MARK: - OAuth PKCE Auditor

public enum OAuthPKCEAuditor {

    // MARK: - PKCE Generator & Verifier (RFC 7636)

    /// Generates a cryptographically secure random verifier and Base64URL-encoded SHA-256 challenge.
    public static func generatePKCEPair(verifierLength: Int = 64) -> PKCEPair {
        let clampedLength = max(43, min(128, verifierLength))
        var randomBytes = [UInt8](repeating: 0, count: clampedLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, clampedLength, &randomBytes)

        let allowedChars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var verifier = ""
        for b in randomBytes {
            verifier.append(allowedChars[Int(b) % allowedChars.count])
        }

        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncode(Data(digest))

        return PKCEPair(verifier: verifier, challenge: challenge, method: "S256")
    }

    /// Verifies that code challenge matches Base64URL(SHA256(verifier)).
    public static func verifyPKCEChallenge(verifier: String, challenge: String) -> Bool {
        guard !verifier.isEmpty, !challenge.isEmpty else { return false }
        guard verifier.count >= 43 && verifier.count <= 128 else { return false }

        let digest = SHA256.hash(data: Data(verifier.utf8))
        let computed = base64URLEncode(Data(digest))
        return computed == challenge
    }

    // MARK: - Authorization URL Builder

    public static func buildAuthorizationURL(config: OAuthAuthorizationURLConfig) -> URL? {
        guard var components = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var items: [URLQueryItem] = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: config.state),
            URLQueryItem(name: "code_challenge", value: config.pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: config.pkce.method)
        ]
        if !config.scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")))
        }

        components.queryItems = items
        return components.url
    }

    // MARK: - Token Request Builders

    public static func buildTokenExchangeRequest(
        tokenEndpoint: URL,
        clientId: String,
        code: String,
        redirectURI: URL,
        codeVerifier: String
    ) -> URLRequest? {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]

        req.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        return req
    }

    public static func buildTokenRefreshRequest(
        tokenEndpoint: URL,
        clientId: String,
        refreshToken: String
    ) -> URLRequest? {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("ApexAgent/1.0", forHTTPHeaderField: "User-Agent")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "refresh_token", value: refreshToken)
        ]

        req.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        return req
    }

    // MARK: - Audit Configuration

    public static func auditConfiguration(
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        redirectURI: URL,
        pkcePair: PKCEPair
    ) -> OAuthAuditReport {
        var violations: [OAuthAuditViolation] = []

        // 1. HTTPS validation for endpoints
        let authScheme = authorizationEndpoint.scheme?.lowercased() ?? ""
        let authHost = authorizationEndpoint.host?.lowercased() ?? ""
        let isAuthLocal = (authHost == "localhost" || authHost == "127.0.0.1")

        if authScheme != "https" && !isAuthLocal {
            violations.append(OAuthAuditViolation(
                code: "INSECURE_AUTHORIZATION_ENDPOINT",
                message: "Authorization endpoint must use HTTPS transport security.",
                isFatal: true
            ))
        }

        let tokenScheme = tokenEndpoint.scheme?.lowercased() ?? ""
        let tokenHost = tokenEndpoint.host?.lowercased() ?? ""
        let isTokenLocal = (tokenHost == "localhost" || tokenHost == "127.0.0.1")

        if tokenScheme != "https" && !isTokenLocal {
            violations.append(OAuthAuditViolation(
                code: "INSECURE_TOKEN_ENDPOINT",
                message: "Token endpoint must use HTTPS transport security.",
                isFatal: true
            ))
        }

        // 2. Redirect URI validation
        let redScheme = redirectURI.scheme?.lowercased() ?? ""
        let isLoopbackRedirect = (redirectURI.host == "localhost" || redirectURI.host == "127.0.0.1")
        let isCustomScheme = !redScheme.hasPrefix("http") && !redScheme.isEmpty

        if !isLoopbackRedirect && redScheme != "https" && !isCustomScheme {
            violations.append(OAuthAuditViolation(
                code: "INSECURE_REDIRECT_URI",
                message: "Redirect URI must be HTTPS, loopback localhost, or private app custom scheme.",
                isFatal: true
            ))
        }

        // 3. PKCE Method & Verifier Validation
        if pkcePair.method != "S256" {
            violations.append(OAuthAuditViolation(
                code: "WEAK_PKCE_METHOD",
                message: "PKCE method must be 'S256' (SHA-256). Plain transformation is disallowed.",
                isFatal: true
            ))
        }

        let isVerified = verifyPKCEChallenge(verifier: pkcePair.verifier, challenge: pkcePair.challenge)
        if !isVerified {
            violations.append(OAuthAuditViolation(
                code: "PKCE_CHALLENGE_MISMATCH",
                message: "Code verifier does not hash to declared code challenge.",
                isFatal: true
            ))
        }

        let fatalCount = violations.filter { $0.isFatal }.count
        let nonFatalCount = violations.filter { !$0.isFatal }.count
        let rawScore = 100.0 - (Double(fatalCount) * 50.0) - (Double(nonFatalCount) * 15.0)
        let finalScore = max(0.0, min(100.0, rawScore))
        let passed = (fatalCount == 0)

        return OAuthAuditReport(
            passed: passed,
            score: finalScore,
            challengeMethod: pkcePair.method,
            isPKCEVerified: isVerified,
            violations: violations
        )
    }

    // MARK: - Base64URL Encoding Helper

    private static func base64URLEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Markdown Formatter

    public static func formatOAuthAuditReportMarkdown(_ report: OAuthAuditReport) -> String {
        var md = "### 🔐 OAuth 2.0 PKCE Authorization & Token Audit\n\n"
        md += "| Parameter | Value |\n"
        md += "|---|---|\n"
        md += "| **Status** | \(report.passed ? "✅ Compliant" : "❌ Non-Compliant") |\n"
        md += "| **Score** | `\(String(format: "%.1f", report.score))%` |\n"
        md += "| **Challenge Method** | `\(report.challengeMethod)` |\n"
        md += "| **PKCE Cryptographic Parity** | `\(report.isPKCEVerified ? "Verified (S256)" : "Failed")` |\n\n"

        if report.violations.isEmpty {
            md += "✨ **Zero violations found.** RFC 7636 PKCE S256 code challenge and token endpoints are compliant.\n"
        } else {
            md += "#### Violations (\(report.violations.count))\n\n"
            for v in report.violations {
                let badge = v.isFatal ? "🔴 FATAL" : "🟡 WARN"
                md += "- \(badge) `\(v.code)`: \(v.message)\n"
            }
        }
        return md
    }
}
