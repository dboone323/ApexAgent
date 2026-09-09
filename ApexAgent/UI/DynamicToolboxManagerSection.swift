import SwiftUI

// MARK: - DynamicToolboxManagerSection: registered MCP server list for Settings

/// Lists the MCP servers registered with the shared `MCPManager` and exposes a
/// per-server delete action. Removing a server also refreshes the dynamic tool
/// registry so stale tools disappear from the toolbox immediately.
struct DynamicToolboxManagerSection: View {
    @State private var mcpManager = MCPManager.shared
    @State private var showDashboard = false
    @State private var showScriptEditor = false

    var body: some View {
        VStack(spacing: 8) {
            ForEach(mcpManager.servers) { config in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name)
                            .fontWeight(.medium)
                        Text("\(config.command) \(config.arguments.joined(separator: " "))")
                            .font(AppTheme.Font.mono(10))
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        mcpManager.removeServer(id: config.id)
                        DynamicToolbox.shared.loadTools()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 12) {
                Button {
                    showDashboard = true
                } label: {
                    Label("MCP Dashboard", systemImage: "server.rack")
                }

                Button {
                    showScriptEditor = true
                } label: {
                    Label("Script Editor", systemImage: "terminal")
                }

                Spacer()
            }
        }
        .sheet(isPresented: $showDashboard) {
            VStack {
                HStack {
                    Spacer()
                    Button("Close") { showDashboard = false }
                        .padding()
                }
                MCPServerDashboardView()
            }
        }
        .sheet(isPresented: $showScriptEditor) {
            VStack {
                HStack {
                    Spacer()
                    Button("Close") { showScriptEditor = false }
                        .padding()
                }
                DynamicScriptEditorView()
            }
        }
    }
}
