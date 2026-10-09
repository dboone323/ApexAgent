import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 91 — Browser Automation DOM Sandbox & URL Restrictions Gate Tests")
struct BrowserSecurityAuditorTests {

    @Test("Valid HTTPS URL passes navigation audit with 100% score")
    func validHttpsURLPasses() {
        let report = BrowserSecurityAuditor.auditNavigationURL("https://developer.apple.com/documentation")

        #expect(report.passed)
        #expect(report.score == 100.0)
        #expect(report.sanitizedURL?.host == "developer.apple.com")
        #expect(report.violations.isEmpty)
    }

    @Test("Bare domain is automatically normalized with https scheme prefix")
    func bareDomainNormalized() {
        let report = BrowserSecurityAuditor.auditNavigationURL("github.com/apexagent")

        #expect(report.passed)
        #expect(report.sanitizedURL?.scheme == "https")
        #expect(report.sanitizedURL?.host == "github.com")
    }

    @Test("Dangerous file and javascript schemes are strictly prohibited")
    func dangerousSchemesBlocked() {
        let fileReport = BrowserSecurityAuditor.auditNavigationURL("file:///etc/passwd")
        #expect(!fileReport.passed)
        #expect(fileReport.violations.contains { $0.code == "PROHIBITED_URL_SCHEME" })

        let jsReport = BrowserSecurityAuditor.auditNavigationURL("javascript:alert(document.cookie)")
        #expect(!jsReport.passed)
        #expect(jsReport.violations.contains { $0.code == "PROHIBITED_URL_SCHEME" })
    }

    @Test("Cloud instance metadata 169.254.169.254 is blocked to prevent SSRF")
    func cloudMetadataBlocked() {
        let report = BrowserSecurityAuditor.auditNavigationURL("http://169.254.169.254/latest/meta-data")

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "CLOUD_METADATA_ENDPOINT_BLOCKED" })
    }

    @Test("Localhost navigation is rejected when disallowed by policy")
    func localhostBlockedWhenDisallowed() {
        var policy = BrowserURLPolicy()
        policy.allowLocalhost = false

        let report = BrowserSecurityAuditor.auditNavigationURL("http://localhost:8080", policy: policy)

        #expect(!report.passed)
        #expect(report.violations.contains { $0.code == "LOCALHOST_NAVIGATION_DISALLOWED" })
    }

    @Test("DOM selector sanitizer allows valid CSS selectors and blocks script injection")
    func domSelectorSanitization() {
        // Valid selectors
        let valid1 = BrowserSecurityAuditor.sanitizeDOMSelector("button.submit-primary")
        #expect(valid1 == "button.submit-primary")

        let valid2 = BrowserSecurityAuditor.sanitizeDOMSelector("#main-container > div:nth-child(2)")
        #expect(valid2 == "#main-container > div:nth-child(2)")

        // Dangerous payloads
        let dangerous1 = BrowserSecurityAuditor.sanitizeDOMSelector("button; eval('alert(1)')")
        #expect(dangerous1 == nil)

        let dangerous2 = BrowserSecurityAuditor.sanitizeDOMSelector("div[data-name=\"test\"]")
        #expect(dangerous2 == nil) // Contains unescaped quotes
    }

    @Test("Scraped content exceeding byte budget is safely truncated with banner")
    func scrapedContentTruncation() {
        let giantString = String(repeating: "abcdefghij", count: 200) // 2000 chars
        let truncated = BrowserSecurityAuditor.sanitizeScrapedContent(giantString, maxBytes: 500)

        #expect(truncated.count < 1000)
        #expect(truncated.contains("[TRUNCATED: Scraped content exceeded 500 bytes]"))
    }
}
