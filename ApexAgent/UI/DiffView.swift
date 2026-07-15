import SwiftUI

struct DiffView: View {
    let oldContent: String
    let newContent: String
    
    @State private var diffLines: [DiffLine] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header showing stats
            HStack {
                let stats = computeStats()
                Label("\(stats.added) additions", systemImage: "plus.circle.fill")
                    .foregroundStyle(.green)
                Label("\(stats.deleted) deletions", systemImage: "minus.circle.fill")
                    .foregroundStyle(.red)
                Spacer()
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { line in
                        HStack(spacing: 8) {
                            // Line number column
                            Text(line.lineNumber != nil ? "\(line.lineNumber!)" : "")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.6))
                                .frame(width: 40, alignment: .trailing)
                                .padding(.leading, 8)
                            
                            // Diff status indicator
                            Text(indicator(for: line.kind))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .frame(width: 15, alignment: .center)
                            
                            // Line text
                            Text(line.text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(lineTextColor(for: line.kind))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 20)
                        .background(rowBackgroundColor(for: line.kind))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(for: line))
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.textBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .onAppear {
            diffLines = DiffHelper.computeDiff(oldText: oldContent, newText: newContent)
        }
        .onChange(of: oldContent) {
            diffLines = DiffHelper.computeDiff(oldText: oldContent, newText: newContent)
        }
        .onChange(of: newContent) {
            diffLines = DiffHelper.computeDiff(oldText: oldContent, newText: newContent)
        }
    }
    
    private func accessibilityLabel(for line: DiffLine) -> String {
        let linePrefix = line.lineNumber != nil ? "Line \(line.lineNumber!), " : ""
        switch line.kind {
        case .added:
            return "\(linePrefix)Added: \(line.text)"
        case .deleted:
            return "\(linePrefix)Deleted: \(line.text)"
        case .unchanged:
            return "\(linePrefix)Unchanged: \(line.text)"
        }
    }
    
    private func indicator(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .unchanged: return " "
        case .added: return "+"
        case .deleted: return "-"
        }
    }
    
    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: return .secondary.opacity(0.4)
        case .added: return .green
        case .deleted: return .red
        }
    }
    
    private func lineTextColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: return .primary
        case .added: return .green.opacity(0.9)
        case .deleted: return .red.opacity(0.9)
        }
    }
    
    private func rowBackgroundColor(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .unchanged: return .clear
        case .added: return .green.opacity(0.08)
        case .deleted: return .red.opacity(0.08)
        }
    }
    
    private func computeStats() -> (added: Int, deleted: Int) {
        let lines = diffLines
        let additions = lines.filter { $0.kind == .added }.count
        let deletions = lines.filter { $0.kind == .deleted }.count
        return (additions, deletions)
    }
}
