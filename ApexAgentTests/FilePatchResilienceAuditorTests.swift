import Foundation
import Testing
@testable import ApexAgentCore

@Suite("Batch 87 — File Patch Tool Fuzzy Chunk & Newline Normalization Gate Tests")
struct FilePatchResilienceAuditorTests {

    @Test("Newline format detection correctly distinguishes LF, CRLF, and mixed endings")
    func newlineFormatDetection() {
        let lfText = "line1\nline2\nline3\n"
        #expect(FilePatchResilienceAuditor.detectNewlineFormat(lfText) == .lf)

        let crlfText = "line1\r\nline2\r\nline3\r\n"
        #expect(FilePatchResilienceAuditor.detectNewlineFormat(crlfText) == .crlf)

        let mixedText = "line1\r\nline2\nline3\r\n"
        #expect(FilePatchResilienceAuditor.detectNewlineFormat(mixedText) == .mixed)
    }

    @Test("Exact patch application preserves CRLF line endings and trailing newline")
    func exactPatchPreservesCRLF() {
        let source = "func testA() {\r\n    print(\"alpha\")\r\n}\r\n"
        let target = "print(\"alpha\")"
        let replacement = "print(\"beta\")"

        let result = FilePatchResilienceAuditor.applyPatch(
            source: source,
            target: target,
            replacement: replacement
        )

        #expect(result.success)
        #expect(result.detectedFormat == .crlf)
        #expect(result.retainedTrailingNewline)
        #expect(result.patchedContent.contains("print(\"beta\")"))
        #expect(result.patchedContent.contains("\r\n"))
        #expect(result.violations.isEmpty)
    }

    @Test("Fuzzy match succeeds when indentation whitespace differs between target and source")
    func fuzzyIndentationMatchSucceeds() {
        let source = "    if isEnabled {\n        performAction()\n        commitState()\n    }\n"
        // Target has different leading indentation
        let target = "if isEnabled {\n    performAction()\n    commitState()\n}"
        let replacement = "if isEnabled {\n    performActionSafely()\n}"

        let result = FilePatchResilienceAuditor.applyPatch(
            source: source,
            target: target,
            replacement: replacement
        )

        #expect(result.success)
        #expect(result.appliedHunksCount == 1)
        #expect(result.patchedContent.contains("performActionSafely()"))
        #expect(!result.patchedContent.contains("commitState()"))
    }

    @Test("Disallowed multiple matches returns MULTIPLE_MATCHES_DISALLOWED violation")
    func multipleMatchesDisallowed() {
        let source = "let x = 1\nlet y = 1\nlet z = 1\n"
        let target = "= 1"
        let replacement = "= 2"

        let result = FilePatchResilienceAuditor.applyPatch(
            source: source,
            target: target,
            replacement: replacement,
            allowMultiple: false
        )

        #expect(!result.success)
        #expect(result.violations.contains { $0.code == "MULTIPLE_MATCHES_DISALLOWED" })
    }

    @Test("Allowed multiple matches replaces all occurrences across file")
    func multipleMatchesAllowed() {
        let source = "var a = 1\nvar b = 1\n"
        let target = "= 1"
        let replacement = "= 99"

        let result = FilePatchResilienceAuditor.applyPatch(
            source: source,
            target: target,
            replacement: replacement,
            allowMultiple: true
        )

        #expect(result.success)
        #expect(result.patchedContent == "var a = 99\nvar b = 99\n")
        #expect(result.appliedHunksCount == 2)
    }

    @Test("Non-existent target chunk returns TARGET_NOT_FOUND violation")
    func targetNotFound() {
        let source = "func calculate() -> Int {\n    return 42\n}\n"
        let target = "func nonExistent() -> Void"

        let result = FilePatchResilienceAuditor.applyPatch(
            source: source,
            target: target,
            replacement: "func replacement()"
        )

        #expect(!result.success)
        #expect(result.violations.contains { $0.code == "TARGET_NOT_FOUND" })
    }

    @Test("Empty target chunk returns EMPTY_TARGET_CONTENT violation")
    func emptyTargetFails() {
        let result = FilePatchResilienceAuditor.applyPatch(
            source: "some content",
            target: "",
            replacement: "new"
        )

        #expect(!result.success)
        #expect(result.violations.contains { $0.code == "EMPTY_TARGET_CONTENT" })
    }
}
