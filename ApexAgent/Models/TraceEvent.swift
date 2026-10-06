import Foundation

struct TraceEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let source: String
    let operation: String
    let detail: String
    let durationMs: TimeInterval?
    let metadata: [String: String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: String,
        operation: String,
        detail: String = "",
        durationMs: TimeInterval? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.operation = operation
        self.detail = detail
        self.durationMs = durationMs
        self.metadata = metadata
    }

    var category: String { source }
    var message: String { detail }
}

extension TraceEvent {
    public func formatAsMarkdown() -> String {
        var md = "### 🔍 Trace: `\(operation)` from `\(source)`\n\n"
        md += "| Field | Value |\n"
        md += "|---|---|\n"
        md += "| Operation | `\(operation)` |\n"
        md += "| Source | `\(source)` |\n"
        if let ms = durationMs {
            md += "| Duration | `\(String(format: "%.1f", ms))ms` |\n"
        }
        if !detail.isEmpty {
            md += "| Detail | \(String(detail.prefix(200)).replacingOccurrences(of: "|", with: "\\|")) |\n"
        }
        return md
    }

    public var isSlow: Bool {
        guard let ms = durationMs else { return false }
        return ms > 1000
    }

    public var isWellFormed: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
