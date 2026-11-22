import SwiftUI
import AppKit
import SharedKit

// MARK: - MCP Registry Browser & Trust View (Issue #87, C2)
//
// In-app browser for the official MCP Registry with:
// - Live browse & search
// - Trust & safety scanning results
// - Permission manifest inspection before install
// - Diff inspection on updates
// - One-click install to MCPManager

public struct MCPRegistryBrowserView: View {
    @State private var mcpManager = MCPManager.shared
    @State private var registryClient = MCPRegistryClient.shared

    @State private var items: [MCPRegistryItem] = []
    @State private var searchQuery: String = ""
    @State private var selectedFilter: RegistryFilter = .all
    @State private var selectedServerId: String?
    @State private var isLoading: Bool = false
    @State private var statusMessage: String?
    @State private var showUpdateDiffSheet: Bool = false
    @State private var showInstallConfirmSheet: Bool = false
    @State private var activeDiff: MCPUpdateDiff?

    public init() {}

    public enum RegistryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case official = "Official"
        case verified = "Verified"
        case unsigned = "Flagged / Unsigned"

        public var id: String { rawValue }
    }

    private var selectedItem: MCPRegistryItem? {
        if let id = selectedServerId {
            return items.first(where: { $0.id == id })
        }
        return items.first
    }

    private var filteredItems: [MCPRegistryItem] {
        items.filter { item in
            let matchesQuery: Bool
            if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                matchesQuery = true
            } else {
                let q = searchQuery.lowercased()
                let nameMatch = item.server.name.lowercased().contains(q)
                let titleMatch = item.server.title?.lowercased().contains(q) ?? false
                let descMatch = item.server.description.lowercased().contains(q)
                matchesQuery = nameMatch || titleMatch || descMatch
            }

            guard matchesQuery else { return false }

            let trust = MCPRegistryTrustScanner.evaluatePublisherTrust(item).trust
            switch selectedFilter {
            case .all:
                return true
            case .official:
                return trust == .officialVerified
            case .verified:
                return trust == .officialVerified || trust == .signedPublisher
            case .unsigned:
                return trust == .unsigned || trust == .untrusted
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar

            Divider()

            if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading MCP Registry...")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe.badge.chevron.backward")
                        .font(.system(size: 36))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                    Text("No Registry Items Found")
                        .font(.headline)
                    Button("Reload") {
                        Task { await loadServers() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    leftServerList
                        .frame(minWidth: 260, maxWidth: 360)

                    if let selected = selectedItem {
                        rightDetailView(selected)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 32))
                                .foregroundStyle(AppTheme.Palette.textTertiary)
                            Text("Select an MCP server from the registry to inspect its security profile and install.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            if let msg = statusMessage {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { statusMessage = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(AppTheme.Palette.accent.opacity(0.1))
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .task {
            await loadServers()
        }
        .sheet(isPresented: $showUpdateDiffSheet) {
            if let diff = activeDiff {
                updateDiffView(diff)
            }
        }
        .sheet(isPresented: $showInstallConfirmSheet) {
            if let item = selectedItem {
                installConfirmationView(item)
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("MCP Registry Browser")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("modelcontextprotocol.io")
                            .font(AppTheme.Font.mono(9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.Palette.accent.opacity(0.15))
                            .cornerRadius(4)
                    }
                    Text("Browse official servers with static analysis, permission manifests, and publisher trust scanning.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()

                Button {
                    Task { await loadServers() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }

            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                    TextField("Search MCP servers, packages, tools...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.Palette.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .background(AppTheme.Palette.windowBackground)
                .cornerRadius(6)

                Picker("", selection: $selectedFilter) {
                    ForEach(RegistryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
        }
        .padding()
        .background(AppTheme.Palette.controlBackground)
    }

    // MARK: - Left Server List

    private var leftServerList: some View {
        List(selection: $selectedServerId) {
            ForEach(filteredItems) { item in
                serverRow(item)
                    .tag(item.id)
            }
        }
    }

    private func serverRow(_ item: MCPRegistryItem) -> some View {
        let server = item.server
        let trust = MCPRegistryTrustScanner.evaluatePublisherTrust(item).trust
        let isInstalled = isServerInstalled(server)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.title ?? server.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                if isInstalled {
                    Text("Installed")
                        .font(AppTheme.Font.mono(9))
                        .foregroundStyle(.green)
                }
            }

            Text(server.description)
                .font(.caption2)
                .foregroundStyle(AppTheme.Palette.textSecondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                trustBadge(trust)

                Text("v\(server.version)")
                    .font(AppTheme.Font.mono(9))
                    .foregroundStyle(AppTheme.Palette.textTertiary)

                Spacer()

                if let pkg = server.packages?.first {
                    Text(pkg.transport.type.uppercased())
                        .font(AppTheme.Font.mono(8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppTheme.Palette.controlBackground)
                        .cornerRadius(3)
                } else if let remote = server.remotes?.first {
                    Text(remote.type.uppercased())
                        .font(AppTheme.Font.mono(8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(AppTheme.Palette.controlBackground)
                        .cornerRadius(3)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Right Detail View

    private func rightDetailView(_ item: MCPRegistryItem) -> some View {
        let report = MCPRegistryTrustScanner.audit(item)
        let isInstalled = isServerInstalled(item.server)
        let installedConfig = mcpManager.servers.first(where: { $0.name == (item.server.title ?? item.server.name) })

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection(item, report: report)
                trustSection(report)
                securityScanSection(report)
                permissionManifestSection(report)
                actionButtons(item: item, isInstalled: isInstalled, installedConfig: installedConfig)
            }
            .padding()
        }
    }

    private func headerSection(_ item: MCPRegistryItem, report: MCPRegistryTrustReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.server.title ?? item.server.name)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(item.server.name)
                        .font(AppTheme.Font.mono(11))
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
                trustBadge(report.publisherTrust, fullText: true)
            }

            Text(item.server.description)
                .font(.body)
                .foregroundStyle(AppTheme.Palette.textPrimary)

            if let website = item.server.websiteUrl {
                Link(destination: URL(string: website) ?? URL(string: "https://modelcontextprotocol.io")!) {
                    Label(website, systemImage: "link")
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(AppTheme.Palette.controlBackground)
        .cornerRadius(8)
    }

    private func trustSection(_ report: MCPRegistryTrustReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Publisher & Trust Verification")
                .font(.headline)

            if report.publisherTrust == .officialVerified {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("Verified by official Model Context Protocol Registry")
                        .font(.caption)
                }
            } else if report.publisherTrust == .signedPublisher {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.blue)
                    Text("Signed and verified publisher via registered package repository")
                        .font(.caption)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unsigned / Untrusted Publisher")
                            .fontWeight(.medium)
                            .font(.caption)
                        Text("This server publisher does not provide verified cryptographic signatures. Review permissions carefully before installing.")
                            .font(.caption2)
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(AppTheme.Palette.controlBackground)
        .cornerRadius(8)
    }

    private func securityScanSection(_ report: MCPRegistryTrustReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Static Security Scan")
                    .font(.headline)
                Spacer()
                if report.findings.isEmpty {
                    Label("Passed Clean", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("\(report.findings.count) Finding(s)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if report.findings.isEmpty {
                Text("No destructive commands, shell wrappers, or suspicious parameters detected in server definition.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            } else {
                ForEach(report.findings) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: finding.severity == .critical ? "xmark.octagon.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(finding.severity == .critical ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("[\(finding.severity.rawValue.uppercased())] \(finding.ruleId)")
                                    .font(AppTheme.Font.mono(10))
                                    .fontWeight(.bold)
                                Spacer()
                                Text(finding.category.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Palette.textTertiary)
                            }
                            Text(finding.message)
                                .font(.caption)
                            if let snippet = finding.snippet {
                                Text(snippet)
                                    .font(AppTheme.Font.mono(9))
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                        }
                    }
                    .padding(6)
                    .background(AppTheme.Palette.windowBackground)
                    .cornerRadius(4)
                }
            }
        }
        .padding()
        .background(AppTheme.Palette.controlBackground)
        .cornerRadius(8)
    }

    private func permissionManifestSection(_ report: MCPRegistryTrustReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Permission Manifest Preview")
                .font(.headline)

            let perms = report.permissionManifest.permissions
            VStack(alignment: .leading, spacing: 6) {
                permissionRow(
                    title: "Outbound Network Access",
                    enabled: perms.allowNetwork,
                    details: perms.allowNetwork ? "Permitted to establish outbound connections" : "No outbound network requested"
                )
                permissionRow(
                    title: "Subprocess & Shell Execution",
                    enabled: perms.allowShell,
                    details: perms.allowShell ? "Spawns local subprocess execution" : "Restricted from shell execution"
                )
                if !perms.filesystemPaths.isEmpty {
                    HStack {
                        Text("Filesystem Access:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Text(perms.filesystemPaths.joined(separator: ", "))
                            .font(AppTheme.Font.mono(10))
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.Palette.controlBackground)
        .cornerRadius(8)
    }

    private func actionButtons(
        item: MCPRegistryItem,
        isInstalled: Bool,
        installedConfig: MCPServerConfig?
    ) -> some View {
        HStack(spacing: 12) {
            if isInstalled {
                if let existing = installedConfig {
                    Button {
                        activeDiff = MCPRegistryTrustScanner.computeUpdateDiff(existing: existing, newServer: item)
                        showUpdateDiffSheet = true
                    } label: {
                        Label("View Update Diff", systemImage: "doc.badge.ellipsis")
                    }
                }

                Button {
                    showInstallConfirmSheet = true
                } label: {
                    Label("Update Server", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    showInstallConfirmSheet = true
                } label: {
                    Label("Install Server", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    private func permissionRow(title: String, enabled: Bool, details: String) -> some View {
        HStack {
            Image(systemName: enabled ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(enabled ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(details)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
            Spacer()
        }
    }

    private func trustBadge(_ level: MCPPublisherTrustLevel, fullText: Bool = false) -> some View {
        let (icon, color): (String, Color) = {
            switch level {
            case .officialVerified: return ("checkmark.seal.fill", .green)
            case .signedPublisher: return ("checkmark.shield.fill", .blue)
            case .communityUnverified: return ("person.2.fill", .gray)
            case .unsigned: return ("exclamationmark.triangle.fill", .orange)
            case .untrusted: return ("xmark.shield.fill", .red)
            }
        }()

        return HStack(spacing: 4) {
            Image(systemName: icon)
            Text(fullText ? level.displayBadge : level.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(AppTheme.Font.mono(9))
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }

    private func isServerInstalled(_ server: MCPRegistryServer) -> Bool {
        let name = server.title ?? server.name
        return mcpManager.servers.contains(where: { $0.name == name })
    }

    private func loadServers() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await registryClient.fetchServers(limit: 50)
            items = fetched
            if selectedServerId == nil {
                selectedServerId = fetched.first?.id
            }
        } catch {
            items = MCPRegistryFixture.sampleServers
            selectedServerId = items.first?.id
        }
    }

    // MARK: - Install Confirmation & Manifest Sheet

    private func installConfirmationView(_ item: MCPRegistryItem) -> some View {
        let report = MCPRegistryTrustScanner.audit(item)

        return VStack(spacing: 16) {
            HStack {
                Text("Confirm Installation: \(item.server.title ?? item.server.name)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { showInstallConfirmSheet = false }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Review the permissions declared by this MCP server before granting execution access:")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)

                let perms = report.permissionManifest.permissions
                VStack(alignment: .leading, spacing: 6) {
                    permissionRow(
                        title: "Network Access",
                        enabled: perms.allowNetwork,
                        details: perms.allowNetwork ? "Allows network requests" : "No network access"
                    )
                    permissionRow(
                        title: "Shell Execution",
                        enabled: perms.allowShell,
                        details: perms.allowShell ? "Spawns process executable" : "No shell access"
                    )
                }
                .padding()
                .background(AppTheme.Palette.controlBackground)
                .cornerRadius(6)

                if report.publisherTrust == .unsigned || report.publisherTrust == .untrusted {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Warning: Publisher is unsigned. Verify server trustworthiness.")
                            .font(.caption)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }

            Spacer()

            HStack {
                Button("Cancel") {
                    showInstallConfirmSheet = false
                }
                Spacer()
                Button("Confirm & Install") {
                    do {
                        let config = try registryClient.installServer(item: item, manager: mcpManager)
                        statusMessage = "Successfully installed '\(config.name)' to MCP servers!"
                        showInstallConfirmSheet = false
                    } catch {
                        statusMessage = "Install error: \(error.localizedDescription)"
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 480, height: 380)
    }

    // MARK: - Update Diff Sheet

    private func updateDiffView(_ diff: MCPUpdateDiff) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Update Diff: \(diff.serverName)")
                    .font(.headline)
                Spacer()
                Button("Close") { showUpdateDiffSheet = false }
            }

            Divider()

            if diff.isPrivilegeEscalation {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Warning: This update introduces new permissions or privilege escalations.")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .padding(8)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(diff.diffs) { field in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(field.fieldName)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                Text("Current: \(field.oldValue)")
                                    .font(AppTheme.Font.mono(10))
                                    .foregroundStyle(.red)
                                Text("New:     \(field.newValue)")
                                    .font(AppTheme.Font.mono(10))
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            if field.isSecurityEscalation {
                                Image(systemName: "exclamationmark.shield.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(8)
                        .background(AppTheme.Palette.controlBackground)
                        .cornerRadius(6)
                    }
                }
            }

            Spacer()

            Button("Done") {
                showUpdateDiffSheet = false
            }
        }
        .padding()
        .frame(width: 520, height: 420)
    }
}
