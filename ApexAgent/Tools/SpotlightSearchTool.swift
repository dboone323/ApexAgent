@preconcurrency import Foundation
import FoundationModels

// MARK: - Spotlight Search Tool (Core Spotlight RAG)
//
// Lets the agent retrieve content from the user's locally indexed files via
// Core Spotlight (the same index Spotlight search uses). This powers
// retrieval-augmented generation over the user's own documents without sending
// anything off-device.

struct SpotlightSearchTool: Tool {
    let orchestrator: OrchestratorProvider

    init(orchestrator: OrchestratorProvider) {
        self.orchestrator = orchestrator
    }

    let name = "spotlight_search"
    let description = "Searches the user's locally indexed files via Core Spotlight (macOS Spotlight). Returns matching file paths with a short content snippet. Use this to ground answers in the user's own documents."

    @Generable
    struct Arguments: Decodable {
        @Guide(description: "The search query (keywords or phrase) to find in indexed local files.")
        var query: String

        @Guide(description: "Maximum number of results to return. Defaults to 10.")
        var maxResults: Int?

        @Guide(description: "Optional file kind filter, e.g. 'public.plain-text', 'public.pdf', 'public.image'.")
        var contentType: String?
    }

    func call(arguments: Arguments) async throws -> String {
        return try await executeWithLogging(arguments: arguments, orchestrator: orchestrator) {
            let maxResults = min(max(arguments.maxResults ?? 10, 1), 50)
            let results = await Self.runSpotlightQuery(
                query: arguments.query,
                maxResults: maxResults,
                contentType: arguments.contentType
            )
            if results.isEmpty {
                return "No Spotlight-indexed results found for '\(arguments.query)'."
            }
            var report = "Found \(results.count) result(s) for '\(arguments.query)':\n\n"
            for (index, item) in results.enumerated() {
                report += "[\(index + 1)] \(item.title)\n"
                report += "    path: \(item.path)\n"
                if let snippet = item.snippet, !snippet.isEmpty {
                    report += "    snippet: \(snippet)\n"
                }
                report += "\n"
            }
            return report
        }
    }

    /// Runs a Core Spotlight query using NSMetadataQuery. Returns best-effort
    /// results; safe to call from any context (synchronously waits on the main
    /// actor for the query to finish, with a 3s watchdog so it cannot hang if
    /// Spotlight is unavailable).
    /// Runs a Core Spotlight query using NSMetadataQuery.
    /// Implemented as a proper async function (withCheckedContinuation) so it
    /// never blocks a thread and is Swift 6 concurrency-safe: all query state
    /// is local to the notification closure, and results are returned via the
    /// continuation rather than a shared mutable `var`.
    static func runSpotlightQuery(query: String, maxResults: Int, contentType: String?) async -> [SpotlightHit] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let queryString: String
        if let contentType {
            queryString = "kMDItemTextContent == '*\(query)*'c && kMDItemContentType == '\(contentType)'"
        } else {
            queryString = "kMDItemTextContent == '*\(query)*'c"
        }

        return await withCheckedContinuation { continuation in
            let metadataQuery = NSMetadataQuery()
            metadataQuery.predicate = NSPredicate(fromMetadataQueryString: queryString)
            metadataQuery.sortDescriptors = [NSSortDescriptor(key: kMDItemFSCreationDate as String, ascending: false)]
            metadataQuery.valueListAttributes = [kMDItemTitle as String, kMDItemPath as String, kMDItemTextContent as String]

            let obsBox = UncheckedSendableBox<NSObjectProtocol?>(nil)
            let queryBoxInner = UncheckedSendableBox(metadataQuery)
            obsBox.value = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: metadataQuery,
                queue: .main
            ) { _ in
                queryBoxInner.value.disableUpdates()
                let count = min(queryBoxInner.value.resultCount, maxResults)
                var hits: [SpotlightHit] = []
                for i in 0..<count {
                    guard let item = queryBoxInner.value.result(at: i) as? NSMetadataItem else { continue }
                    let title = (item.value(forAttribute: kMDItemTitle as String) as? String)
                        ?? (item.value(forAttribute: kMDItemFSName as String) as? String)
                        ?? "Untitled"
                    let path = (item.value(forAttribute: kMDItemPath as String) as? String) ?? ""
                    let rawContent = item.value(forAttribute: kMDItemTextContent as String) as? String ?? ""
                    let snippet = rawContent.isEmpty ? nil : String(rawContent.prefix(200))
                    hits.append(SpotlightHit(title: title, path: path, snippet: snippet))
                }
                queryBoxInner.value.stop()
                if let obs = obsBox.value { NotificationCenter.default.removeObserver(obs) }
                continuation.resume(returning: hits)
            }

            // Watchdog: if the gather never completes (Spotlight unavailable),
            // resume with an empty result so the caller is never stranded.
            let watchdogBox = UncheckedSendableBox(metadataQuery)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                DispatchQueue.main.async {
                    watchdogBox.value.stop()
                    if let obs = obsBox.value { NotificationCenter.default.removeObserver(obs) }
                    continuation.resume(returning: [])
                }
            }

            metadataQuery.start()
        }
    }
}

/// Sendable gate that guarantees `leave()` is called at most once, so the
/// DispatchGroup wait cannot over-leave if both the gather callback and the
/// watchdog fire.
final class SpotlightQueryGate: @unchecked Sendable {
    let group = DispatchGroup()
    private var hasLeft = false
    private let lock = NSLock()

    func enter() { group.enter() }
    func leave() {
        lock.lock()
        defer { lock.unlock() }
        if !hasLeft {
            hasLeft = true
            group.leave()
        }
    }
    func wait() { group.wait() }
    /// Bounded wait — returns on gather/watchdog leave() or after `timeout`
    /// seconds, whichever comes first. Never blocks the caller forever.
    @discardableResult
    func wait(timeout seconds: TimeInterval) -> DispatchTimeoutResult {
        group.wait(timeout: .now() + seconds)
    }
}

struct SpotlightHit: Sendable {
    let title: String
    let path: String
    let snippet: String?
}

/// Minimal box to move a non-Sendable reference across queues when the usage
/// pattern is known-safe (here: NSMetadataQuery is only ever touched on main).
final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
