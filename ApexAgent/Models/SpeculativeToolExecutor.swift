import Foundation
import Observation

// Tools that are safe to speculate on (read-only, idempotent, no side effects)
let speculableToolNames: Set<String> = [
    "read_file", "file_search", "list_directory",
    "get_system_info", "search_memory", "query_logs"
]

@Observable
@MainActor
public final class SpeculativeToolExecutor {
    public static let shared = SpeculativeToolExecutor()
    
    // Cache: (toolName + jsonArguments) -> (result, cachedAt)
    private var cache: [String: (result: String, cachedAt: Date)] = [:]
    private var pendingSpeculations: [String: Task<String, Error>] = [:]
    private let cacheTTLSeconds: TimeInterval = 30.0
    
    // Cache stats for diagnostics
    public var cacheHitCount: Int = 0
    public var cacheMissCount: Int = 0
    public var hitRate: Double {
        let total = cacheHitCount + cacheMissCount
        guard total > 0 else { return 0.0 }
        return Double(cacheHitCount) / Double(total)
    }
    
    private init() {}
    
    private func buildKey(toolName: String, jsonArguments: String) -> String {
        // Normalize jsonArguments by sorting keys alphabetically before hashing
        if let data = jsonArguments.data(using: .utf8),
           let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            // Sort keys
            let sortedKeys = jsonObject.keys.sorted()
            let normalizedElements = sortedKeys.map { "\($0):\(jsonObject[$0]!)" }
            let normalizedArgs = normalizedElements.joined(separator: ",")
            return "\(toolName)::{\(normalizedArgs)}"
        }
        return "\(toolName)::\(jsonArguments)"
    }
    
    // Pre-dispatch a tool speculatively. Safe to call with unconfirmed arguments.
    public func speculate(toolName: String, jsonArguments: String, executor: @escaping (String, String) async throws -> String) {
        guard speculableToolNames.contains(toolName) else { return }
        
        let key = buildKey(toolName: toolName, jsonArguments: jsonArguments)
        
        if let cached = cache[key] {
            if Date().timeIntervalSince(cached.cachedAt) < cacheTTLSeconds {
                return // Already cached and not expired
            }
        }
        
        if pendingSpeculations[key] != nil {
            return // Task already pending
        }
        
        let task = Task {
            try await executor(toolName, jsonArguments)
        }
        pendingSpeculations[key] = task
        
        Task {
            do {
                let result = try await task.value
                self.cache[key] = (result: result, cachedAt: Date())
            } catch {
                // Ignore errors during speculation
            }
            self.pendingSpeculations[key] = nil
        }
    }
    
    // Resolve: returns cached result if speculation matched, else nil
    public func resolve(toolName: String, jsonArguments: String) async -> String? {
        let key = buildKey(toolName: toolName, jsonArguments: jsonArguments)
        
        if let cached = cache[key] {
            if Date().timeIntervalSince(cached.cachedAt) < cacheTTLSeconds {
                cacheHitCount += 1
                return cached.result
            }
        }
        
        if let pendingTask = pendingSpeculations[key] {
            do {
                let result = try await pendingTask.value
                cacheHitCount += 1
                return result
            } catch {
                // Task failed
                cacheMissCount += 1
                return nil
            }
        }
        
        cacheMissCount += 1
        return nil
    }
    
    // Invalidate all cache entries (e.g. when a write tool executes)
    public func invalidateAll() {
        for task in pendingSpeculations.values {
            task.cancel()
        }
        pendingSpeculations.removeAll()
        cache.removeAll()
    }

    // MARK: - Markdown Metrics

    public func formatMetricsMarkdown() -> String {
        var md = "### ⚡️ Speculative Tool Execution Telemetry\n\n"
        md += "| Metric | Value | Description |\n"
        md += "|---|---|---|\n"
        md += "| Speculative Cache Hits | `\(cacheHitCount)` | Queries resolved immediately from pre-execution |\n"
        md += "| Speculative Cache Misses | `\(cacheMissCount)` | Queries requiring full synchronous execution |\n"
        md += "| Speculation Hit Rate | `\(String(format: "%.1f%%", hitRate * 100))` | Ratio of speculative matches |\n"
        md += "| Active In-Flight Tasks | `\(pendingSpeculations.count)` | Currently executing background speculative tasks |\n"
        md += "| Active Cached Entries | `\(cache.count)` | Valid speculative results in memory |\n"
        md += "| Cache TTL | `\(String(format: "%.0fs", cacheTTLSeconds))` | Cache freshness lifetime |\n"
        return md
    }

}