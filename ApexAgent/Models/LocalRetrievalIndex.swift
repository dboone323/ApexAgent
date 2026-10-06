import Foundation
import CoreSpotlight
import FoundationModels
import _CoreSpotlight_FoundationModels

/// Local retrieval surface for ApexAgent.
///
/// WWDC26/382 announced **CoreSpotlight RAG** as a new macOS 27 retrieval tool
/// for the Foundation Models framework. Unlike a hand-rolled Spotlight query,
/// Apple ships a first-class `SpotlightSearchTool` (in
/// `_CoreSpotlight_FoundationModels`) that conforms to `FoundationModels.Tool`
/// and drops straight into `LanguageModelSession(tools:)`. This module wraps it
/// (`CoreSpotlightRAG`) and keeps a deterministic `NSMetadataQuery` fallback
/// (`SpotlightRetrievalIndex`) for headless/test use.
public protocol LocalRetrievalIndex: Sendable {
    /// Return the most relevant local items for a natural-language query.
    func search(_ query: String, limit: Int) async -> [RetrievalItem]
}

public struct RetrievalItem: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let content: String
    public let url: URL?

    public init(id: String, title: String, content: String, url: URL?) {
        self.id = id
        self.title = title
        self.content = content
        self.url = url
    }
}

/// Real CoreSpotlight RAG via Apple's `SpotlightSearchTool`.
///
/// `SpotlightSearchTool` is `: FoundationModels.Tool`, so it can be attached to
/// any `LanguageModelSession` (including ApexAgent's `LanguageModel` sessions)
/// in one line — the model then performs retrieval-augmented generation against
/// the user's Spotlight index with no embeddings or vector DB.
public enum CoreSpotlightRAG {
    /// Build a `SpotlightSearchTool` ready to pass to `LanguageModelSession(tools:)`.
    /// - Parameters:
    ///   - sources: which indexes to search (default: the user's CoreSpotlight index).
    ///   - guide: how aggressively to expand the query (`.complete` by default).
    ///   - maximumResponseSize: optional cap on retrieved bytes.
    public static func makeTool(
        maximumResponseSize: Int? = nil
    ) -> _CoreSpotlight_FoundationModels.SpotlightSearchTool {
        let configuration = _CoreSpotlight_FoundationModels.SpotlightSearchTool.Configuration(
            sources: [.coreSpotlight],
            guide: .complete,
            maximumResponseSize: maximumResponseSize
        )
        return _CoreSpotlight_FoundationModels.SpotlightSearchTool(configuration: configuration)
    }

    /// Whether the CoreSpotlight RAG API is available on this OS.
    /// True on macOS 27 beta (the framework ships in the SDK).
    public static var isAvailable: Bool { true }
}

/// Deterministic, network-free Spotlight retrieval backed by `NSMetadataQuery`.
/// Useful in tests and when a plain list of matching items is preferred over
/// the model-driven RAG tool.
public struct SpotlightRetrievalIndex: LocalRetrievalIndex {
    public init() {}

    public func search(_ text: String, limit: Int = 8) async -> [RetrievalItem] {
        await withCheckedContinuation { continuation in
            // NSMetadataQuery is documented single-thread-use; its lifetime is
            // fully contained here and notifications are delivered on `.main`,
            // so the @Sendable observer block below can safely touch it.
            nonisolated(unsafe) let metadataQuery = NSMetadataQuery()
            metadataQuery.searchScopes = [NSMetadataQueryLocalComputerScope]
            metadataQuery.predicate = NSPredicate(
                format: "kMDItemDisplayName LIKE[c] %@ OR kMDItemTextContent LIKE[c] %@",
                "*\(text)*", "*\(text)*"
            )
            // The observer removes itself on first fire; a tiny box guards
            // against double-resume when the watchdog below fires instead.
            final class OnceBox: @unchecked Sendable {
                private let lock = NSLock()
                private var claimed = false
                var token: NSObjectProtocol?
                func claim() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if claimed { return false }
                    claimed = true
                    return true
                }
            }
            let once = OnceBox()
            let center = NotificationCenter.default
            once.token = center.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                guard once.claim() else { return }
                if let token = once.token {
                    center.removeObserver(token)
                }
                metadataQuery.stop()
                var items: [RetrievalItem] = []
                for i in 0..<min(metadataQuery.resultCount, limit) {
                    guard let item = metadataQuery.result(at: i) as? NSMetadataItem else { continue }
                    let name = (item.value(forAttribute: NSMetadataItemDisplayNameKey) as? String) ?? "Untitled"
                    let path = (item.value(forAttribute: NSMetadataItemPathKey) as? String) ?? ""
                    let content = (item.value(forAttribute: NSMetadataItemTextContentKey) as? String) ?? ""
                    items.append(RetrievalItem(
                        id: path,
                        title: name,
                        content: String(content.prefix(280)),
                        url: URL(fileURLWithPath: path)
                    ))
                }
                continuation.resume(returning: items)
            }
            // Watchdog: if Spotlight (mds) is stalled or disabled the gathering
            // notification never fires and the continuation would leak. Bound
            // the wait and degrade to "no results" instead of hanging forever.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                guard once.claim() else { return }
                if let token = once.token { center.removeObserver(token) }
                metadataQuery.stop()
                continuation.resume(returning: [])
            }
            metadataQuery.start()
        }
    }
}

/// Backwards-compatible availability probe (now reflects the real API).
@available(*, deprecated, message: "CoreSpotlight RAG is available; use CoreSpotlightRAG.isAvailable.")
public enum CoreSpotlightRAGAvailability {
    public static var isAvailable: Bool { CoreSpotlightRAG.isAvailable }
}


// MARK: - Markdown Results Table
extension SpotlightRetrievalIndex {
    public static func formatResultsTable(_ items: [RetrievalItem]) -> String {
        guard !items.isEmpty else {
            return "No local items matched the Spotlight retrieval query."
        }

        var md = "### 🔍 Spotlight RAG Retrieved Documents (\(items.count) matches)\n\n"
        md += "| Document Title | File Path | Preview Content |\n"
        md += "|---|---|---|\n"

        for item in items {
            let safeTitle = item.title.replacingOccurrences(of: "|", with: "\\|")
            let safePath = (item.url?.path ?? item.id).replacingOccurrences(of: "|", with: "\\|")
            let safeSnippet = item.content.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
            md += "| **\(safeTitle)** | `\(safePath)` | \(safeSnippet) |\n"
        }
        return md
    }
}
