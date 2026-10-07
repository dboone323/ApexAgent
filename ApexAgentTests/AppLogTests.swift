import Testing
import Foundation
import SwiftUI
import AppKit
@testable import ApexAgentCore

// MARK: - AppLog: level gating, ring buffer, category routing & Diagnostics wiring
//
// Real entries through the real AppLog funnel — no fakes. The suite runs
// serialized because it gates and clears the process-wide buffer; assertions
// are marker-based so concurrent logging from other suites cannot flake them.
// Global state (minimumLevel, buffer) is restored by the per-test init.

@Suite("AppLogTests", .serialized)
struct AppLogTests {

    init() {
        AppLog.clearBuffer()
        AppLog.minimumLevel = .debug
    }

    @Test func levelGatingDropsBelowMinimum() {
        AppLog.minimumLevel = .error
        AppLog.info(.orchestrator, "marker dropped info")
        AppLog.notice(.orchestrator, "marker dropped notice")
        #expect(!AppLog.recentEntries().contains { $0.message == "marker dropped info" })
        #expect(!AppLog.recentEntries().contains { $0.message == "marker dropped notice" })

        AppLog.error(.orchestrator, "marker kept error")
        let kept = AppLog.recentEntries().first { $0.message == "marker kept error" }
        #expect(kept?.level == .error)
        AppLog.minimumLevel = .debug
    }

    @Test func ringBufferEvictsOldestBeyondCapacity() {
        AppLog.clearBuffer()
        // Own 550 entries: > capacity guarantees our oldest is evicted and
        // the buffer can never exceed its bound, regardless of other suites.
        for i in 0..<550 {
            AppLog.info(.app, "evict-check \(i)")
        }
        let entries = AppLog.recentEntries()
        #expect(entries.count == AppLog.bufferCapacity)
        #expect(!entries.contains { $0.message == "evict-check 0" })
        #expect(entries.contains { $0.message == "evict-check 549" })
    }

    @Test func recentEntriesLimitAndNewestFirst() {
        AppLog.clearBuffer()
        for i in 0..<10 {
            AppLog.info(.bot, "limit-check \(i)")
        }
        let five = AppLog.recentEntries(limit: 5)
        #expect(five.count == 5)
        // Our newest marker is present in the limited window and ordered
        // newest-first relative to our older markers that made the window.
        let ours = AppLog.recentEntries(limit: 50).filter { $0.message.hasPrefix("limit-check") }
        #expect(ours.count == 10)
        #expect(ours.first?.message == "limit-check 9")
        #expect(AppLog.recentEntries(limit: 0).isEmpty)
    }

    @Test func clearRemovesBufferedEntries() {
        AppLog.info(.bot, "marker cleared")
        #expect(AppLog.recentEntries().contains { $0.message == "marker cleared" })
        AppLog.clearBuffer()
        #expect(!AppLog.recentEntries().contains { $0.message == "marker cleared" })
    }

    @Test func categoryRoutingIsRecorded() {
        AppLog.info(.gateway, "marker category gateway")
        AppLog.error(.spotlight, "marker category spotlight")
        let gw = AppLog.recentEntries().first { $0.message == "marker category gateway" }
        let sp = AppLog.recentEntries().first { $0.message == "marker category spotlight" }
        #expect(gw?.category == .gateway)
        #expect(gw?.level == .info)
        #expect(sp?.category == .spotlight)
        #expect(sp?.level == .error)
    }

    @Test func errorOverloadAppendsErrorDescription() {
        struct SampleError: LocalizedError {
            var errorDescription: String? { "disk exploded" }
        }
        AppLog.error(.security, "marker backup failed", error: SampleError())
        let entry = AppLog.recentEntries().first { $0.message.hasPrefix("marker backup failed") }
        #expect(entry?.message.hasSuffix("disk exploded") == true)
        #expect(entry?.level == .error)
    }

    @Test func debugEntriesRecordedWhenGateAllows() {
        AppLog.debug(.toolbox, "marker debug entry")
        #expect(AppLog.recentEntries().contains { $0.level == .debug && $0.message == "marker debug entry" })
    }

    @Test func faultLevelRecordedAndOutranksError() {
        AppLog.minimumLevel = .fault
        AppLog.error(.security, "marker dropped error below fault")
        AppLog.fault(.security, "marker critical fault")
        #expect(!AppLog.recentEntries().contains { $0.message == "marker dropped error below fault" })
        let faultEntry = AppLog.recentEntries().first { $0.message.hasPrefix("marker critical fault") }
        #expect(faultEntry?.level == .fault)
        #expect(faultEntry?.level.label == "FAULT")
        AppLog.minimumLevel = .debug
    }

    @Test func concurrentLoggingIsBoundedAndLosslessBelowCapacity() {
        AppLog.clearBuffer()
        let workers = 8
        let perWorker = 40 // 320 entries: large headroom below capacity so
                           // foreign entries from other suites can't evict ours
        DispatchQueue.concurrentPerform(iterations: workers * perWorker) { i in
            AppLog.info(.app, "conc-\(i)")
        }
        let ours = AppLog.recentEntries().filter { $0.message.hasPrefix("conc-") }
        #expect(ours.count == workers * perWorker)
        #expect(Set(ours.map(\.message)).count == workers * perWorker)
        #expect(AppLog.recentEntries().count <= AppLog.bufferCapacity)
        AppLog.clearBuffer()
    }

    // MARK: RecentLogsModel — the production code behind Diagnostics' section

    @Test func recentLogsModelRefreshesFromRealBuffer() {
        AppLog.clearBuffer()
        AppLog.info(.routine, "marker model sees this")
        let model = RecentLogsModel()
        model.refresh()
        #expect(model.entries.contains { $0.message == "marker model sees this" })
        #expect(model.entries.first?.category == .routine)
        #expect(model.total >= 1)
    }

    @Test func recentLogsModelClearEmptiesRealBuffer() {
        // This is the exact production path behind the section's Clear button.
        AppLog.error(.gateway, "marker to be cleared")
        let model = RecentLogsModel()
        model.refresh()
        #expect(model.entries.contains { $0.message == "marker to be cleared" })

        model.clear()
        #expect(!AppLog.recentEntries().contains { $0.message == "marker to be cleared" })
        #expect(model.entries.isEmpty)
        #expect(model.total == 0)
        #expect(model.countText() == "0 entries")
    }

    @Test func recentLogsModelCountTextFormatting() {
        // Pure formatting covers every branch without racing the shared buffer.
        #expect(RecentLogsModel.countText(shown: 0, total: 0) == "0 entries")
        #expect(RecentLogsModel.countText(shown: 1, total: 1) == "1 entry")
        #expect(RecentLogsModel.countText(shown: 5, total: 5) == "5 entries")
        #expect(RecentLogsModel.countText(shown: 50, total: 60) == "showing 50 of 60")
        #expect(RecentLogsModel.countText(shown: 499, total: 500) == "showing 499 of 500")
    }

    @Test @MainActor func diagnosticsViewHostsWithRecentLogsSectionRendered() {
        // In-process SwiftUI controls expose no NSButton/AX handles (verified
        // against the AppKit subtree and the AX tree), so hosting asserts real
        // rendering; the Clear action is exercised through the same model call
        // the rendered button invokes.
        AppLog.error(.gateway, "marker hosted sample")
        let model = RecentLogsModel()
        model.refresh()
        #expect(model.entries.contains { $0.message == "marker hosted sample" })
        model.clear()
        #expect(!AppLog.recentEntries().contains { $0.message == "marker hosted sample" })

        // Leave one entry so the section renders its rows + scroll container.
        AppLog.info(.app, "marker rendered section row")

        let handle = ViewHost.hostWithHandle(DiagnosticsView())
        handle.pump(duration: 0.3)
        #expect(handle.hosting.frame.width > 0)
        #expect(handle.hosting.frame.height > 0)
        // The section's scroll container materialized in the view tree.
        let subviewNames = handle.allSubviews().map { String(describing: type(of: $0)) }
        #expect(subviewNames.contains { $0.contains("HostingScrollView") })
    }
}
