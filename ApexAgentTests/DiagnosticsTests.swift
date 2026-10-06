import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Diagnostic summary rendering

@Suite("DiagnosticSummaryTests")
struct DiagnosticSummaryTests {
    @Test func diagnosticSummary() {
        let items = [
            DiagnosticItem(name: "Git", category: "CLI", status: .pass, message: "ok"),
            DiagnosticItem(name: "Node", category: "CLI", status: .warning, message: "missing"),
            DiagnosticItem(name: "Xcode", category: "CLI", status: .fail, message: "missing")
        ]
        let md = DiagnosticItem.summarizeAsMarkdown(items)
        #expect(md.contains("3 checks"))
        #expect(md.contains("1 failing"))
        #expect(DiagnosticItem.summarizeAsMarkdown([]).contains("No diagnostic"))
    }
}
