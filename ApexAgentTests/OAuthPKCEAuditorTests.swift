//
//  OAuthPKCEAuditorTests.swift
//  ApexAgentTests
//
//  Created for Batch 119: OAuth 2.0 PKCE (RFC 7636) Authorization & Token Refresh Auditor Tests.
//

import Testing
import Foundation
import CryptoKit
@testable import ApexAgentCore

@Suite("Batch 119 — OAuth 2.0 PKCE & Token Refresh Auditor Tests")
struct OAuthPKCEAuditorTests {

    @Test("generatePKCEPair produces RFC 7636 compliant verifier and S256 challenge")
    func testGeneratePKCEPair() {
        let pair = OAuthPKCEAuditor.generatePKCEPair(verifierLength: 64)
        #expect(pair.method == "S256")
        #expect(pair.verifier.count == 64)
        #expect(!pair.challenge.isEmpty)

        // RFC 7636 unreserved characters only
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        #expect(pair.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })

        // Cryptographic verification
        let isValid = OAuthPKCEAuditor.verifyPKCEChallenge(verifier: pair.verifier, challenge: pair.challenge)
        #expect(isValid)
    }

    @Test("verifyPKCEChallenge accurately verifies matching hashes and rejects tampered verifiers")
    func testVerifyPKCEChallenge() {
        let pair = OAuthPKCEAuditor.generatePKCEPair(verifierLength: 50)
        #expect(OAuthPKCEAuditor.verifyPKCEChallenge(verifier: pair.verifier, challenge: pair.challenge))

        // Tampered verifier
        let tamperedVerifier = pair.verifier + "x"
        #expect(!OAuthPKCEAuditor.verifyPKCEChallenge(verifier: tamperedVerifier, challenge: pair.challenge))

        // Tampered challenge
        let tamperedChallenge = pair.challenge + "a"
        #expect(!OAuthPKCEAuditor.verifyPKCEChallenge(verifier: pair.verifier, challenge: tamperedChallenge))
    }

    @Test("buildAuthorizationURL constructs complete RFC 7636 authorization query string")
    func testBuildAuthorizationURL() throws {
        let pkce = OAuthPKCEAuditor.generatePKCEPair(verifierLength: 64)
        let config = OAuthAuthorizationURLConfig(
            authorizationEndpoint: URL(string: "https://auth.example.com/oauth/authorize")!,
            clientId: "apexagent-client-id-123",
            redirectURI: URL(string: "http://127.0.0.1:8080/callback")!,
            scopes: ["read:issues", "write:comments"],
            state: "state_nonce_random_999",
            pkce: pkce
        )

        let authURL = try #require(OAuthPKCEAuditor.buildAuthorizationURL(config: config))
        let components = try #require(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        let queryMap = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(queryMap["response_type"] == "code")
        #expect(queryMap["client_id"] == "apexagent-client-id-123")
        #expect(queryMap["redirect_uri"] == "http://127.0.0.1:8080/callback")
        #expect(queryMap["scope"] == "read:issues write:comments")
        #expect(queryMap["state"] == "state_nonce_random_999")
        #expect(queryMap["code_challenge"] == pkce.challenge)
        #expect(queryMap["code_challenge_method"] == "S256")
    }

    @Test("buildTokenExchangeRequest formats application/x-www-form-urlencoded body")
    func testBuildTokenExchangeRequest() throws {
        let req = OAuthPKCEAuditor.buildTokenExchangeRequest(
            tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
            clientId: "apex-client-42",
            code: "auth_code_sample_123",
            redirectURI: URL(string: "http://127.0.0.1:8080/callback")!,
            codeVerifier: "sample_code_verifier_1234567890123456789012345678901234567890123"
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")

        let bodyData = try #require(request.httpBody)
        let bodyString = try #require(String(data: bodyData, encoding: .utf8))
        #expect(bodyString.contains("grant_type=authorization_code"))
        #expect(bodyString.contains("client_id=apex-client-42"))
        #expect(bodyString.contains("code=auth_code_sample_123"))
    }

    @Test("buildTokenRefreshRequest formats grant_type=refresh_token body")
    func testBuildTokenRefreshRequest() throws {
        let req = OAuthPKCEAuditor.buildTokenRefreshRequest(
            tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
            clientId: "apex-client-42",
            refreshToken: "refresh_tok_sample_999"
        )

        let request = try #require(req)
        #expect(request.httpMethod == "POST")
        let bodyData = try #require(request.httpBody)
        let bodyString = try #require(String(data: bodyData, encoding: .utf8))
        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=refresh_tok_sample_999"))
    }

    @Test("auditConfiguration passes with 100% score for valid HTTPS endpoints and valid PKCE pair")
    func testValidAuditConfiguration() {
        let pkce = OAuthPKCEAuditor.generatePKCEPair(verifierLength: 64)
        let report = OAuthPKCEAuditor.auditConfiguration(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            redirectURI: URL(string: "https://apexagent.app/oauth/callback")!,
            pkcePair: pkce
        )

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.isPKCEVerified)
        #expect(report.challengeMethod == "S256")
        #expect(report.violations.isEmpty)
    }

    @Test("Insecure HTTP endpoints and mismatched PKCE pair trip fatal violations")
    func testInsecureAndMismatchedTripViolations() {
        let badPair = PKCEPair(verifier: "invalid_verifier_here_43_chars_long_1234567890", challenge: "wrong_challenge")
        let report = OAuthPKCEAuditor.auditConfiguration(
            authorizationEndpoint: URL(string: "http://remote.auth.com/authorize")!,
            tokenEndpoint: URL(string: "http://remote.auth.com/token")!,
            redirectURI: URL(string: "http://remote.auth.com/callback")!,
            pkcePair: badPair
        )

        #expect(!report.passed)
        #expect(report.violations.contains(where: { $0.code == "INSECURE_AUTHORIZATION_ENDPOINT" }))
        #expect(report.violations.contains(where: { $0.code == "INSECURE_TOKEN_ENDPOINT" }))
        #expect(report.violations.contains(where: { $0.code == "PKCE_CHALLENGE_MISMATCH" }))
    }

    @Test("formatOAuthAuditReportMarkdown renders markdown summary table")
    func testMarkdownFormatting() {
        let pkce = OAuthPKCEAuditor.generatePKCEPair()
        let report = OAuthPKCEAuditor.auditConfiguration(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            tokenEndpoint: URL(string: "https://auth.example.com/token")!,
            redirectURI: URL(string: "https://apexagent.app/callback")!,
            pkcePair: pkce
        )

        let md = OAuthPKCEAuditor.formatOAuthAuditReportMarkdown(report)
        #expect(md.contains("OAuth 2.0 PKCE Authorization & Token Audit"))
        #expect(md.contains("S256"))
        #expect(md.contains("✅ Compliant"))
        #expect(md.contains("100.0%"))
    }
}
