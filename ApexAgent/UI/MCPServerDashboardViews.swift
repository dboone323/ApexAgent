import SwiftUI
import AppKit

// MARK: - MCPServerDashboardView: Production MCP Server Inspection & Control

public struct MCPServerDashboardView: View {
    @State private var mcpManager = MCPManager.shared
    @State private var selectedServerId: UUID?
    @State private var serverHealth: [UUID: MCPClientHealth] = [:]
    @State private var latencies: [UUID: Double] = [:]
    @State private var serverTools: [UUID: [MCPToolDefinition]] = [:]
    @State private var isProbing: Bool = false
    @State private var statusMessage: String? = nil

    public init() {}

    private var selectedConfig: MCPServerConfig? {
        if let id = selectedServerId {
            return mcpManager.servers.first(where: { $0.id == id })
        }
        return mcpManager.servers.first
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP Server Dashboard")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("Inspect health, measure latency, view registered tools, and manage circuit breakers.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
                Button {
                    Task { await refreshAll() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(isProbing)
            }
            .padding()
            .background(AppTheme.Palette.controlBackground)

            Divider()

            if mcpManager.servers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 36))
                        .foregroundStyle(AppTheme.Palette.textTertiary)
                    Text("No MCP Servers Configured")
                        .font(.headline)
                    Text("Add MCP servers in Settings to inspect connection telemetry and tools.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                HSplitView {
                    // Left Column: Server List
                    List(selection: $selectedServerId) {
                        Section("Registered Servers (\(mcpManager.servers.count))") {
                            ForEach(mcpManager.servers) { server in
                                serverRow(server)
                                    .tag(server.id)
                            }
                        }
                    }
                    .frame(minWidth: 220, maxWidth: 280)

                    // Right Column: Server Details & Tools
                    if let config = selectedConfig {
                        serverDetailView(config)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Select a server to view diagnostics")
                            .foregroundStyle(AppTheme.Palette.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            if let msg = statusMessage {
                Divider()
                HStack {
                    Image(systemName: "info.circle")
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
        .frame(minWidth: 640, minHeight: 480)
        .task {
            if selectedServerId == nil {
                selectedServerId = mcpManager.servers.first?.id
            }
            await refreshAll()
        }
    }

    private func serverRow(_ server: MCPServerConfig) -> some View {
        let health = serverHealth[server.id]
        let latency = latencies[server.id]

        return HStack {
            Circle()
                .fill(statusColor(for: health))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(.medium)
                Text(server.transport.uppercased())
                    .font(AppTheme.Font.mono(9))
                    .foregroundStyle(AppTheme.Palette.textTertiary)
            }

            Spacer()

            if let lat = latency {
                Text("\(String(format: "%.1f", lat)) ms")
                    .font(AppTheme.Font.mono(10))
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func serverDetailView(_ server: MCPServerConfig) -> some View {
        let health = serverHealth[server.id]
        let latency = latencies[server.id]
        let tools = serverTools[server.id] ?? []

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Status & Controls Card
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .font(.title3)
                                .fontWeight(.bold)
                            Text("\(server.command) \(server.arguments.joined(separator: " "))")
                                .font(AppTheme.Font.mono(11))
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                        }
                        Spacer()
                        statusBadge(for: health)
                    }

                    Divider()

                    // Action Controls
                    HStack(spacing: 12) {
                        Button {
                            Task { await probeServer(server) }
                        } label: {
                            Label("Ping Latency", systemImage: "waveform.path.ecg")
                        }
                        .disabled(isProbing)

                        Button {
                            Task {
                                await mcpManager.resetClientCircuit(id: server.id)
                                await refreshServer(server)
                                statusMessage = "Circuit breaker reset for \(server.name)"
                            }
                        } label: {
                            Label("Reset Circuit", systemImage: "bolt.badge.checkmark")
                        }

                        Button {
                            Task {
                                do {
                                    try await mcpManager.restartServer(id: server.id)
                                    await refreshServer(server)
                                    statusMessage = "Restarted \(server.name)"
                                } catch {
                                    statusMessage = "Restart failed: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            Label("Restart", systemImage: "arrow.triangle.2.circlepath")
                        }

                        Spacer()
                    }

                    // Metrics row
                    HStack(spacing: 20) {
                        metricPill(title: "Transport", value: server.transport.uppercased())
                        metricPill(title: "Latency", value: latency != nil ? "\(String(format: "%.1f", latency!)) ms" : "Unmeasured")
                        metricPill(title: "Failures", value: "\(health?.failureCount ?? 0)")
                        metricPill(title: "Restarts", value: "\(health?.restartCountInWindow ?? 0)")
                    }
                    .padding(.top, 4)
                }
                .padding()
                .background(AppTheme.Palette.controlBackground)
                .cornerRadius(8)

                // Tools Section
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Discovered Tools (\(tools.count))")
                            .font(.headline)
                        Spacer()
                        Button("Reload Tools") {
                            Task { await loadTools(for: server) }
                        }
                        .font(.caption)
                    }

                    if tools.isEmpty {
                        HStack {
                            Spacer()
                            Text("No dynamic tools discovered or server not started yet.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Palette.textSecondary)
                                .padding()
                            Spacer()
                        }
                        .background(AppTheme.Palette.controlBackground.opacity(0.5))
                        .cornerRadius(6)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(tools, id: \.name) { tool in
                                toolCard(tool)
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.Palette.textTertiary)
            Text(value)
                .font(AppTheme.Font.mono(11))
                .fontWeight(.medium)
        }
    }

    private func badgeInfo(for health: MCPClientHealth?) -> (text: String, color: Color) {
        guard let h = health else { return ("Unknown", .secondary) }
        if h.circuitOpen { return ("Circuit Open", .red) }
        if h.isRunning { return ("Running", .green) }
        return ("Stopped", .secondary)
    }

    private func statusBadge(for health: MCPClientHealth?) -> some View {
        let info = badgeInfo(for: health)
        return Text(info.text)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(info.color.opacity(0.15))
            .foregroundStyle(info.color)
            .clipShape(Capsule())
    }

    private func statusColor(for health: MCPClientHealth?) -> Color {
        badgeInfo(for: health).color
    }

    @ViewBuilder
    private func toolCard(_ tool: MCPToolDefinition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tool.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Dynamic Tool")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Palette.accent)
            }

            if let desc = tool.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Palette.textSecondary)
            }

            if let props = tool.inputSchema.properties, !props.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parameters:")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Palette.textTertiary)

                    ForEach(props.keys.sorted(), id: \.self) { paramKey in
                        let prop = props[paramKey]
                        let isReq = tool.inputSchema.required?.contains(paramKey) ?? false
                        HStack(alignment: .firstTextBaseline) {
                            Text(paramKey)
                                .font(AppTheme.Font.mono(10))
                                .fontWeight(isReq ? .bold : .regular)
                            if isReq {
                                Text("(required)")
                                    .font(.caption2)
                                    .foregroundStyle(Color.red)
                            }
                            if let type = prop?.type {
                                Text(":\(type)")
                                    .font(AppTheme.Font.mono(9))
                                    .foregroundStyle(AppTheme.Palette.textTertiary)
                            }
                            if let desc = prop?.description {
                                Text("— \(desc)")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                        }
                    }
                }
                .padding(6)
                .background(AppTheme.Palette.controlBackground.opacity(0.6))
                .cornerRadius(4)
            }
        }
        .padding(10)
        .background(AppTheme.Palette.controlBackground)
        .cornerRadius(6)
    }

    private func refreshAll() async {
        isProbing = true
        defer { isProbing = false }

        for server in mcpManager.servers {
            await refreshServer(server)
        }
    }

    private func refreshServer(_ server: MCPServerConfig) async {
        let client = mcpManager.getClient(for: server)
        let health = await client.health()
        serverHealth[server.id] = health

        if health.isRunning {
            await loadTools(for: server)
        }
    }

    private func probeServer(_ server: MCPServerConfig) async {
        isProbing = true
        defer { isProbing = false }

        let client = mcpManager.getClient(for: server)
        if let latency = await client.measureLatency() {
            latencies[server.id] = latency
            statusMessage = "Ping successful: \(String(format: "%.1f", latency)) ms"
        } else {
            statusMessage = "Ping failed or server is not running"
        }
        await refreshServer(server)
    }

    private func loadTools(for server: MCPServerConfig) async {
        let client = mcpManager.getClient(for: server)
        if let tools = try? await client.listRegisteredTools() {
            serverTools[server.id] = tools
        }
    }
}


// MARK: - DynamicScriptEditorView: In-App Script Authoring & Live Console

public struct DynamicScriptEditorView: View {
    @State private var scriptEntries: [ScriptEntry] = []
    @State private var selectedScriptId: String?
    @State private var scriptName: String = ""
    @State private var scriptDescription: String = ""
    @State private var scriptContent: String = "#!/usr/bin/env bash\n# Apex Dynamic Tool Script\necho \"Running script with input: $1\"\nexit 0\n"
    @State private var testArguments: String = "{\"query\": \"sample\"}"
    @State private var consoleOutput: String = ""
    @State private var isRunning: Bool = false
    @State private var lastExitCode: Int? = nil
    @State private var lastDuration: TimeInterval? = nil
    @State private var statusAlert: String? = nil

    public struct ScriptEntry: Identifiable, Hashable {
        public let id: String
        public let name: String
        public let scriptPath: String
        public let manifestPath: String?
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Top Bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dynamic Script Editor")
                        .font(.headline)
                        .fontWeight(.semibold)
                    Text("Author shell scripts in ~/.apex/skills, test-run with live console, and hot-reload.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                }
                Spacer()
                Button {
                    newScript()
                } label: {
                    Label("New Script", systemImage: "plus")
                }
                Button {
                    saveAndHotReload()
                } label: {
                    Label("Save & Hot-Reload", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(AppTheme.Palette.controlBackground)

            Divider()

            HSplitView {
                // Left Column: Script list
                List(selection: $selectedScriptId) {
                    Section("Local Custom Scripts (\(scriptEntries.count))") {
                        ForEach(scriptEntries) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.body)
                                    .fontWeight(.medium)
                                Text(entry.scriptPath)
                                    .font(AppTheme.Font.mono(9))
                                    .foregroundStyle(AppTheme.Palette.textTertiary)
                                    .lineLimit(1)
                            }
                            .tag(entry.id)
                        }
                    }
                }
                .frame(minWidth: 200, maxWidth: 260)
                .onChange(of: selectedScriptId) { _, newId in
                    if let id = newId, let entry = scriptEntries.first(where: { $0.id == id }) {
                        loadScript(entry)
                    }
                }

                // Center & Right: Editor and Live Runner Console
                VSplitView {
                    // Top: Metadata & Code Editor
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            TextField("Tool Name (e.g. repo_grep)", text: $scriptName)
                                .font(.headline)
                                .textFieldStyle(.roundedBorder)

                            TextField("Description", text: $scriptDescription)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text("Bash / Zsh Script Content:")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Palette.textSecondary)

                        TextEditor(text: $scriptContent)
                            .font(AppTheme.Font.mono(11))
                            .frame(minHeight: 180)
                            .padding(4)
                            .background(AppTheme.Palette.controlBackground)
                            .cornerRadius(6)
                    }
                    .padding()

                    // Bottom: Live Test Console
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Test Runner Console")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Spacer()
                            if let exit = lastExitCode {
                                Text("Exit: \(exit)")
                                    .font(AppTheme.Font.mono(10))
                                    .foregroundStyle(exit == 0 ? Color.green : Color.red)
                            }
                            if let dur = lastDuration {
                                Text("\(String(format: "%.2f", dur))s")
                                    .font(AppTheme.Font.mono(10))
                                    .foregroundStyle(AppTheme.Palette.textSecondary)
                            }
                            Button {
                                Task { await runTestScript() }
                            } label: {
                                Label("Run Test", systemImage: "play.fill")
                            }
                            .disabled(isRunning)
                        }

                        HStack {
                            Text("JSON Input:")
                                .font(.caption)
                            TextField("Arguments JSON", text: $testArguments)
                                .font(AppTheme.Font.mono(10))
                                .textFieldStyle(.roundedBorder)
                        }

                        ScrollView {
                            Text(consoleOutput.isEmpty ? "Console output will appear here after execution..." : consoleOutput)
                                .font(AppTheme.Font.mono(10))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .foregroundStyle(consoleOutput.isEmpty ? AppTheme.Palette.textTertiary : AppTheme.Palette.textPrimary)
                        }
                        .frame(minHeight: 120)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(6)
                    }
                    .padding()
                }
            }

            if let alert = statusAlert {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                    Text(alert)
                        .font(.caption)
                    Spacer()
                    Button("Dismiss") { statusAlert = nil }
                        .font(.caption)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.1))
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .task {
            loadScriptFiles()
        }
    }

    private func loadScriptFiles() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let skillsDir = home.appendingPathComponent(".apex/skills")
        let toolsDir = home.appendingPathComponent(".apex/tools")

        var found: [ScriptEntry] = []
        for dir in [skillsDir, toolsDir] {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "sh" {
                let base = item.deletingPathExtension().lastPathComponent
                let manifest = dir.appendingPathComponent("\(base).json")
                let hasManifest = fm.fileExists(atPath: manifest.path)
                found.append(ScriptEntry(
                    id: item.path,
                    name: base,
                    scriptPath: item.path,
                    manifestPath: hasManifest ? manifest.path : nil
                ))
            }
        }
        self.scriptEntries = found
        if selectedScriptId == nil, let first = found.first {
            selectedScriptId = first.id
            loadScript(first)
        }
    }

    private func loadScript(_ entry: ScriptEntry) {
        if let content = try? String(contentsOfFile: entry.scriptPath, encoding: .utf8) {
            self.scriptContent = content
        }
        self.scriptName = entry.name
        if let manifestPath = entry.manifestPath,
           let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.scriptDescription = json["description"] as? String ?? ""
        }
    }

    private func newScript() {
        self.selectedScriptId = nil
        self.scriptName = "custom_tool"
        self.scriptDescription = "Custom dynamic tool"
        self.scriptContent = "#!/usr/bin/env bash\n# Custom Tool\necho \"Hello from Apex Dynamic Tool!\"\nexit 0\n"
        self.consoleOutput = ""
        self.lastExitCode = nil
    }

    private func saveAndHotReload() {
        let name = scriptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".apex/skills")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let scriptURL = dir.appendingPathComponent("\(name).sh")
        let manifestURL = dir.appendingPathComponent("\(name).json")

        do {
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let manifest: [String: Any] = [
                "name": name,
                "description": scriptDescription,
                "script_path": scriptURL.path,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "Script input parameter"
                        ]
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted])
            try data.write(to: manifestURL)

            DynamicToolbox.shared.loadTools()
            SkillManager.shared.syncFromDisk()
            loadScriptFiles()
            statusAlert = "Successfully saved and reloaded '\(name)' into DynamicToolbox."
        } catch {
            statusAlert = "Save error: \(error.localizedDescription)"
        }
    }

    private func runTestScript() async {
        isRunning = true
        consoleOutput = "Starting execution...\n"
        let start = Date()

        let script = scriptContent
        let args = testArguments

        let result = await Task.detached { () -> (exitCode: Int, output: String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script, "runner", args]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let outStr = String(data: data, encoding: .utf8) ?? ""
                return (Int(process.terminationStatus), outStr)
            } catch {
                return (-1, "Process launch error: \(error.localizedDescription)")
            }
        }.value

        lastDuration = Date().timeIntervalSince(start)
        lastExitCode = result.exitCode
        consoleOutput = result.output
        isRunning = false
    }
}
