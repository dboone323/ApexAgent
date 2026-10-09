import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 74 — Interactive PTY Terminal ANSI Escape Sanitizer Gate Tests")
struct TerminalSecurityGateTests {

    @Test("Safe ANSI colored output passes audit with 100% score and untouched content")
    func safeANSIColoredOutputPasses() {
        let text = "\u{001B}[32mSuccess: Build finished in 2.4s\u{001B}[0m\n\u{001B}[1;34mInfo: 0 warnings\u{001B}[0m"
        let result = TerminalSecurityGate.sanitize(text)

        #expect(result.report.passed)
        #expect(result.report.score == 100.0)
        #expect(result.report.violations.isEmpty)
        #expect(result.sanitizedText == text)
        #expect(result.report.strippedSequencesCount == 0)
    }

    @Test("OSC 52 clipboard injection sequence is stripped and flagged as violation")
    func osc52ClipboardInjectionStripped() {
        // OSC 52 sequence attempting to read or write base64 clipboard content
        let malicious = "Normal output...\u{001B}]52;c;c3VwZXJfc2VjcmV0\u{0007}...continued text"
        let result = TerminalSecurityGate.sanitize(malicious)

        #expect(!result.report.passed)
        #expect(result.report.violations.contains { $0.kind == .clipboardEscapeInjection })
        #expect(!result.sanitizedText.contains("\u{001B}]52;"))
        #expect(!result.sanitizedText.contains("c3VwZXJfc2VjcmV0"))
        #expect(result.sanitizedText.contains("Normal output......continued text"))
    }

    @Test("OSC 0 window title escape sequence is stripped and flagged")
    func oscTitleHijackingStripped() {
        let malicious = "\u{001B}]0;Spoofed Window Title\u{0007}Prompt> "
        let result = TerminalSecurityGate.sanitize(malicious)

        #expect(!result.report.passed)
        #expect(result.report.violations.contains { $0.kind == .titleEscapeManipulation })
        #expect(!result.sanitizedText.contains("Spoofed Window Title"))
        #expect(result.sanitizedText == "Prompt> ")
    }

    @Test("CSI 6n Device Status Report command query is stripped to prevent input injection")
    func dsrInputInjectionStripped() {
        let text = "Listing files:\n\u{001B}[6nfile1.txt\nfile2.txt"
        let result = TerminalSecurityGate.sanitize(text)

        #expect(!result.report.passed)
        #expect(result.report.violations.contains { $0.kind == .deviceStatusReportQuery })
        #expect(!result.sanitizedText.contains("\u{001B}[6n"))
        #expect(result.sanitizedText.contains("Listing files:\nfile1.txt\nfile2.txt"))
    }

    @Test("Dangerous raw control characters are stripped from terminal stream")
    func controlCharactersStripped() {
        let rawWithNulAndBel = "Header\u{0000}\u{0007}\u{0005}Data"
        let result = TerminalSecurityGate.sanitize(rawWithNulAndBel)

        #expect(!result.report.passed)
        #expect(result.report.violations.contains { $0.kind == .rawControlCharacter })
        #expect(result.sanitizedText == "HeaderData")
    }

    @Test("Oversized terminal chunk is truncated and flagged")
    func oversizedChunkTruncated() {
        let largeChunk = String(repeating: "A", count: 2000)
        let config = TerminalSecurityConfig(maxChunkBytes: 1000)
        let result = TerminalSecurityGate.sanitize(largeChunk, config: config)

        #expect(!result.report.passed)
        #expect(result.report.violations.contains { $0.kind == .oversizedStreamChunk })
        #expect(result.sanitizedText.count == 1000)
    }
}
