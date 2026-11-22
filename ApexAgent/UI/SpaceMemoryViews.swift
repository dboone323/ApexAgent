import SwiftUI
import SharedKit
import AppKit

// MARK: - Space Memory Inspector View

public struct SpaceMemoryInspectorView: View {
    public let space: SpaceModel?
    public let workspacePath: String?

    @State private var searchText = ""
    @State private var selectedItemForSource: MemoryTopicItem?
    @State private var editingItem: MemoryTopicItem?
    @State private var editKeyText = ""
    @State private var editStatementText = ""
    @State private var showImportSheet = false
    @State private var showExportSheet = false
    @State private var exportedMarkdownText = ""
    @State private var importMarkdownText = ""
    @State private var refreshTrigger = UUID()
    @State private var isNoMemoryActive: Bool = false

    private var effectiveWorkspace: String {
        SpaceMemoryInspectorManager.shared.resolveWorkspacePath(space: space, workspacePath: workspacePath)
    }

    public init(space: SpaceModel? = nil, workspacePath: String? = nil) {
        self.space = space
        self.workspacePath = workspacePath
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    noMemoryBanner
                    searchBar

                    let groups = filteredTopicGroups
                    if groups.isEmpty {
                        ContentUnavailableView(
                            "No Memory Topics",
                            systemImage: "brain",
                            description: Text(searchText.isEmpty
                                ? "This Space does not have any recorded memory blocks or topics yet."
                                : "No memory records matching '\(searchText)'.")
                        )
                        .padding(.vertical, 32)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(groups) { group in
                                topicGroupCard(group: group)
                            }
                        }
                    }

                    if let selected = selectedItemForSource {
                        Divider()
                            .padding(.vertical, 6)
                        sourceProvenancePanel(item: selected)
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            syncState()
        }
        .sheet(isPresented: $showImportSheet) {
            importSheetView
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheetView
        }
        .sheet(item: $editingItem) { item in
            editItemSheetView(item: item)
        }
    }

    private func syncState() {
        isNoMemoryActive = SpaceMemoryInspectorManager.shared.isNoMemoryModeEnabled(for: space, workspacePath: effectiveWorkspace)
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text("Inspectable Memory")
                    .font(.system(size: 13, weight: .bold))
                Text(space?.name ?? "Active Space")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                let md = SpaceMemoryInspectorManager.shared.exportMarkdown(space: space, workspacePath: effectiveWorkspace)
                exportedMarkdownText = md
                showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Export memory set to Markdown")
            .accessibilityIdentifier("spaceMemoryExportButton")

            Button {
                importMarkdownText = ""
                showImportSheet = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Import memory set from Markdown")
            .accessibilityIdentifier("spaceMemoryImportButton")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - No-Memory / Incognito Banner

    private var noMemoryBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: isNoMemoryActive ? "eye.slash.fill" : "brain")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isNoMemoryActive ? .purple : AppTheme.Palette.accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("No-Memory Session Mode")
                            .font(.system(size: 12, weight: .semibold))

                        if isNoMemoryActive {
                            Text("INCOGNITO ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.18))
                                .foregroundStyle(.purple)
                                .clipShape(Capsule())
                        }
                    }

                    Text("When active, sessions run without writing new entries or distilling facts into memory.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { isNoMemoryActive },
                    set: { newVal in
                        isNoMemoryActive = newVal
                        SpaceMemoryInspectorManager.shared.setNoMemoryMode(newVal, for: space, workspacePath: effectiveWorkspace)
                        refreshTrigger = UUID()
                    }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("spaceNoMemoryToggle")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isNoMemoryActive ? Color.purple.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isNoMemoryActive ? Color.purple.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Search topics, facts, or citations...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    // MARK: - Topics List & Cards

    private var allTopicGroups: [MemoryTopicGroup] {
        _ = refreshTrigger
        return SpaceMemoryInspectorManager.shared.loadTopics(space: space, workspacePath: effectiveWorkspace)
    }

    private var filteredTopicGroups: [MemoryTopicGroup] {
        let groups = allTopicGroups
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            return groups
        }
        let q = searchText.lowercased()
        return groups.compactMap { group in
            if group.topic.lowercased().contains(q) {
                return group
            }
            let matchingItems = group.items.filter { item in
                item.statement.lowercased().contains(q)
                    || item.sourceCitation.lowercased().contains(q)
                    || item.tier.lowercased().contains(q)
            }
            if !matchingItems.isEmpty {
                return MemoryTopicGroup(topic: group.topic, items: matchingItems, isPaused: group.isPaused)
            }
            return nil
        }
    }

    private func topicGroupCard(group: MemoryTopicGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 8) {
                Text(group.topic)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))

                if group.isPaused {
                    Text("PAUSED")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                } else {
                    Text("ACTIVE")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                }

                Spacer()

                // Pause / Resume Toggle Button
                Button {
                    if group.isPaused {
                        SpaceMemoryInspectorManager.shared.resumeTopic(group.topic, space: space, workspacePath: effectiveWorkspace)
                    } else {
                        SpaceMemoryInspectorManager.shared.pauseTopic(group.topic, space: space, workspacePath: effectiveWorkspace)
                    }
                    refreshTrigger = UUID()
                } label: {
                    Label(
                        group.isPaused ? "Resume" : "Pause",
                        systemImage: group.isPaused ? "play.circle.fill" : "pause.circle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(group.isPaused ? .green : .orange)
                .accessibilityIdentifier("pauseTopicButton_\(group.topic)")

                // Delete Topic Button
                Button {
                    try? SpaceMemoryInspectorManager.shared.deleteTopic(group.topic, space: space, workspacePath: effectiveWorkspace)
                    if selectedItemForSource?.key.lowercased() == group.topic.lowercased() {
                        selectedItemForSource = nil
                    }
                    refreshTrigger = UUID()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Delete entire topic")
                .accessibilityIdentifier("deleteTopicButton_\(group.topic)")
            }

            Divider()

            // Memory items inside topic
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.items) { item in
                    memoryItemRow(item: item)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(group.isPaused ? Color.orange.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func memoryItemRow(item: MemoryTopicItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.statement)
                .font(.system(size: 12))
                .foregroundStyle(item.isPaused ? .secondary : .primary)

            HStack(spacing: 6) {
                Text(item.sourceCitation)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                tierBadge(item.tier)

                if !item.dateString.isEmpty {
                    Text(item.dateString)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // "Why do you think that?" Source Button
                Button {
                    if selectedItemForSource?.id == item.id {
                        selectedItemForSource = nil
                    } else {
                        selectedItemForSource = item
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "questionmark.circle.fill")
                        Text("Why?")
                    }
                    .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(selectedItemForSource?.id == item.id ? AppTheme.Palette.accent : .secondary)
                .help("View source citation and provenance: Why do you think that?")
                .accessibilityIdentifier("whyDoYouThinkThatButton_\(item.key)")

                // Edit Button
                Button {
                    editingItem = item
                    editKeyText = item.key
                    editStatementText = item.statement
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Edit this memory fact")
                .accessibilityIdentifier("editTopicItemButton_\(item.key)")

                // Delete Item Button
                Button {
                    try? SpaceMemoryInspectorManager.shared.deleteItem(item, space: space, workspacePath: effectiveWorkspace)
                    if selectedItemForSource?.id == item.id {
                        selectedItemForSource = nil
                    }
                    refreshTrigger = UUID()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this memory fact")
            }
        }
        .padding(6)
        .background(Color.primary.opacity(selectedItemForSource?.id == item.id ? 0.05 : 0.02))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tierBadge(_ tier: String) -> some View {
        let (color, label): (Color, String) = {
            switch tier.lowercased() {
            case "curated": return (.blue, "Curated")
            case "daily": return (.teal, "Daily")
            case "persona": return (.purple, "Persona")
            case "user": return (.indigo, "User")
            default: return (.gray, tier.capitalized)
            }
        }()

        return Text(label)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - "Why Do You Think That?" Source Panel

    private func sourceProvenancePanel(item: MemoryTopicItem) -> some View {
        let provenance = SpaceMemoryInspectorManager.shared.provenance(for: item)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.Palette.accent)

                Text("Source Provenance — \"Why do you think that?\"")
                    .font(.system(size: 12, weight: .bold))

                Spacer()

                Button {
                    selectedItemForSource = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(provenance.sourceCitation)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text("File: \(provenance.relativePath) (\(provenance.lineRange))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                // Verbatim Source Snippet Box
                VStack(alignment: .leading, spacing: 4) {
                    Text("VERBATIM SOURCE TEXT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)

                    Text(provenance.verbatimSourceSnippet)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                        )
                }

                // Provenance answer
                Text(provenance.provenanceAnswer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.Palette.accent.opacity(0.35), lineWidth: 1.5)
        )
        .accessibilityIdentifier("memorySourcePanel")
    }

    // MARK: - Edit Item Sheet

    private func editItemSheetView(item: MemoryTopicItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Memory Fact")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Topic / Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Key (e.g. database_host)", text: $editKeyText)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Statement")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $editStatementText)
                    .font(.system(size: 12))
                    .frame(height: 100)
                    .border(Color.secondary.opacity(0.2))
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    editingItem = nil
                }

                Button("Save Fact") {
                    try? SpaceMemoryInspectorManager.shared.editItem(
                        item,
                        newKey: editKeyText,
                        newStatement: editStatementText,
                        space: space,
                        workspacePath: effectiveWorkspace
                    )
                    editingItem = nil
                    refreshTrigger = UUID()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
        .accessibilityIdentifier("editTopicSheet")
    }

    // MARK: - Export Sheet

    private var exportSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export Memory Set (Markdown)")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showExportSheet = false
                }
            }

            TextEditor(text: .constant(exportedMarkdownText))
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 280)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Spacer()
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(exportedMarkdownText, forType: .string)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .accessibilityIdentifier("exportMarkdownSheet")
    }

    // MARK: - Import Sheet

    private var importSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import Memory Set (Markdown)")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    showImportSheet = false
                }
            }

            Text("Paste a Markdown memory document to restore or update topics and facts for this Space.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $importMarkdownText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 240)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Spacer()
                Button("Import Memory") {
                    _ = try? SpaceMemoryInspectorManager.shared.importMarkdown(
                        importMarkdownText,
                        space: space,
                        workspacePath: effectiveWorkspace
                    )
                    showImportSheet = false
                    refreshTrigger = UUID()
                }
                .buttonStyle(.borderedProminent)
                .disabled(importMarkdownText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 400)
        .accessibilityIdentifier("importMarkdownSheet")
    }
}
