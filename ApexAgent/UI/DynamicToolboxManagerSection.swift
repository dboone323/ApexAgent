import SwiftUI

// MARK: - DynamicToolboxManagerSection: registered MCP server list for Settings

/// Lists the MCP servers registered with the shared `MCPManager` and exposes a
/// per-server delete action. Removing a server also refreshes the dynamic tool
/// registry so stale tools disappear from the toolbox immediately.
struct DynamicToolboxManagerSection: View {
    @State private var mcpManager = MCPManager.shared

    var body: some View {
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
    }
}
