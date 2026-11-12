import AppKit
import Carbon
import CoreSpotlight
import Foundation
import FoundationModels
import Intents
import SwiftData
import SwiftUI
import SharedKit
import os

@MainActor
public struct ApexAgentApp: App {
    let orchestrator = AppDelegate.sharedOrchestrator
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var botManager: BotManager
    @State private var spaceManager = SpaceManager.shared
    let computer: Computer
    @State private var skillManager = SkillManager.shared
    @State private var routineManager = RoutineManager.shared

    private var isTestMode: Bool {
        ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
    }

    public init() {
        self.computer = Computer()
        let bm = BotManager(orchestrator: orchestrator, computer: computer)
        self.botManager = bm
        orchestrator.botManager = bm
        SpaceManager.shared.orchestrator = orchestrator
        SpaceManager.shared.botManager = bm
        ContainerBridge.shared = ContainerManager.shared
        let args = CommandLine.arguments
        // Attempt to connect to background daemon gateway if explicitly requested or reachable.
        // Probing reachability avoids Network.framework ECONNREFUSED socket error noise when
        // running in standalone GUI mode without the daemon.
        Task { @MainActor in
            let shouldConnect = UserDefaults.standard.bool(forKey: "apex.connectGateway")
                || args.contains("--connect-gateway")
            if shouldConnect || ApexGatewayClient.isServerReachable() {
                ApexGatewayClient.shared.connect()
            }
        }
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
                .environment(botManager)
                .environment(spaceManager)
                .environment(computer)
                .environment(\.skillManager, skillManager)
                .environment(routineManager)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    GlobalCommandPaletteController.shared.registerHotKey()
                }
                .onOpenURL { url in
                    _ = DeepLinkNavigationState.shared.handle(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { userActivity in
                    if let uniqueIdentifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        _ = SpotlightIndexer.handleSpotlightActivation(uniqueIdentifier: uniqueIdentifier)
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .modelContainer(
            for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self, SpacePageProposal.self],
            inMemory: isTestMode
        )
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    botManager.activeBotId = nil
                    spaceManager.activeSpaceId = nil
                    ShortcutRegistry.shared.dispatch(.newChat, orchestrator: orchestrator)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette…") {
                    ShortcutRegistry.shared.dispatch(.commandPalette, orchestrator: orchestrator)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("System Diagnostics…") {
                    ShortcutRegistry.shared.dispatch(.showDiagnostics, orchestrator: orchestrator)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            CommandMenu("Go") {
                Button("Routines") {
                    ShortcutRegistry.shared.dispatch(.goRoutines, orchestrator: orchestrator)
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Skills") {
                    ShortcutRegistry.shared.dispatch(.goSkills, orchestrator: orchestrator)
                }
                .keyboardShortcut("2", modifiers: .command)

            }

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Apex Agent Documentation & Guide") {
                    if let url = URL(string: "https://github.com/dboone323/ApexAgent#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("/", modifiers: [.command, .shift])

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/dboone323/ApexAgent/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(orchestrator)
                .environment(botManager)
                .environment(spaceManager)
                .environment(computer)
                .environment(\.skillManager, skillManager)
                .environment(skillManager)
                .environment(routineManager)
                .modelContainer(
                    for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self, SpacePageProposal.self],
                    inMemory: isTestMode
                )
        }
    }
}

@MainActor
public class AppDelegate: NSObject, NSApplicationDelegate, OrchestratorProvider {
    public static var sharedOrchestrator = AgentOrchestrator()
    var orchestrator: AgentOrchestrator {
        return AppDelegate.sharedOrchestrator
    }
    var dataBus: AppGroupDataBus {
        return AppGroupDataBus.shared
    }

    func sessionForAgent(
        agent: RegisteredAgent,
        preference: AgentModelPreference,
        instructions: String,
        allowedTools: [String],
        toolCallingMode: GenerationOptions.ToolCallingMode,
        reasoningLevel: ContextOptions.ReasoningLevel?,
        maxResponseTokens: Int?,
        history: Transcript?
    ) -> LanguageModelSession {
        orchestrator.sessionForAgent(
            agent: agent,
            preference: preference,
            instructions: instructions,
            allowedTools: allowedTools,
            toolCallingMode: toolCallingMode,
            reasoningLevel: reasoningLevel,
            maxResponseTokens: maxResponseTokens,
            history: history
        )
    }

    var statusItem: NSStatusItem?
    private var webhookServer: WebhookServer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        MetricDiagnosticsCenter.shared.start()
        setupStatusItem()
        setupGlobalHotkey()
        setupShortcuts()
        setupSpotlight()
        Task.detached(priority: .utility) {
            Self.checkFMCLIAvailability()
        }
        startWebhookReceiverIfPossible()
    }

    /// Handles macOS standard Help menu and shortcut (⌘?) routing to official documentation.
    @IBAction public func showHelp(_ sender: Any?) {
        if let url = URL(string: "https://github.com/dboone323/ApexAgent#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    /// O5: serve .webhook routines while the GUI runs. If the port is taken
    /// (e.g. the daemon is already bound), its receiver covers us — non-fatal.
    private func startWebhookReceiverIfPossible() {
        let manager = WebhookManager.shared
        let server = WebhookServer(manager: manager)
        do {
            try server.start(preferredPort: 1338)
            self.webhookServer = server
        } catch {
            AppLog.error(.app, "WebhookServer: port 1338 unavailable (daemon may be running): \(error)")
        }
    }

    nonisolated private static func checkFMCLIAvailability() {
        let fmPath = "/usr/bin/fm"
        guard FileManager.default.isExecutableFile(atPath: fmPath) else {
            return
        }
        // Probe that `fm` actually responds (it is gated behind `sudo fm license` on macOS 27).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fmPath)
        process.arguments = ["available"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                UserDefaults.standard.set(true, forKey: "apex.fmCLIAvailable")
            } else {
                UserDefaults.standard.set(false, forKey: "apex.fmCLIAvailable")
            }
        } catch {
            UserDefaults.standard.set(false, forKey: "apex.fmCLIAvailable")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Apex Agent")
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Open Apex Agent", action: #selector(openApp), keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            statusItem?.menu = menu
        }
    }

    @objc private func openApp() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupGlobalHotkey() {
        // Option + Space hotkey handled via Carbon EventHotKey in GlobalCommandPaletteController
    }

    private func setupShortcuts() {
        // App Intents / Shortcuts integration
    }

    private func setupSpotlight() {
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }
}

extension AppDelegate {
    @MainActor
    public static func runCLIMode(prompt: String, allowTools: Bool = false) async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        AppLog.info(.app, "=== RUNNING CLI TEST ===")
        AppLog.info(.app, "Prompt: \(prompt)")

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        orchestrator.toolCallingMode = allowTools ? .auto : .disabled

        do {
            let schema = Schema([
                Conversation.self, Message.self, AgentMemory.self, AppPermissions.self,
                ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self,
                ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self,
                SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self, SpacePageProposal.self
            ])
            let isTestMode = ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: isTestMode)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let mainContext = ModelContext(container)
            orchestrator.modelContext = mainContext
            botManager.modelContext = mainContext
            botManager.loadBotsFromDisk()
            if let url = container.configurations.first?.url {
                AppLog.info(.app, "🧠 SwiftData Store URL: \(url.path)")
            }
        } catch {
            AppLog.error(.app, "⚠️ Failed to initialize SwiftData model context: \(error)")
        }

        try? await Task.sleep(for: .seconds(1))

        await orchestrator.sendMessageAndWait(prompt)

        AppLog.info(.app, "\n=== TOOL EVENTS ===")
        if orchestrator.toolEvents.isEmpty {
            AppLog.info(.app, "No tools called.")
        } else {
            for event in orchestrator.toolEvents.reversed() {
                AppLog.info(.app, "Tool: \(event.toolName)")
                AppLog.info(.app, "Args: \(event.arguments)")
                AppLog.info(.app, "Result: \(event.result ?? "nil")")
                AppLog.info(.app, "Status: \(event.status)")
                AppLog.info(.app, "-------------------")
            }
        }

        AppLog.info(.app, "\n=== FINAL RESPONSE ===")
        if let lastMessage = orchestrator.messages.last(where: { $0.role == .assistant }) {
            AppLog.info(.app, lastMessage.content)
        } else {
            AppLog.info(.app, "No response received")
        }
        AppLog.info(.app, "=======================")
    }
}

@MainActor
public func runDaemonMode() async {
    AppLog.info(.app, "=== RUNNING DAEMON MODE ===")
    let orchestrator = AgentOrchestrator()
    let mainContext: ModelContext?
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self, SpacePageProposal.self)
        let context = ModelContext(container)
        mainContext = context
        orchestrator.modelContext = context
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        botManager.modelContext = context
        botManager.loadBotsFromDisk()
        RoutineManager.shared.modelContext = context
        RoutineManager.shared.botManager = botManager
        RoutineManager.shared.loadRoutines()
        RoutineManager.shared.startScheduledRoutines()
        if let url = container.configurations.first?.url {
            AppLog.info(.app, "🧠 SwiftData Store URL: \(url.path)")
        }
    } catch {
        AppLog.error(.app, "⚠️ Failed to initialize SwiftData model context: \(error)")
        mainContext = nil
    }

    let server = ApexGatewayServer(port: 1337, orchestrator: orchestrator)
    let isRunning = OSAllocatedUnfairLock<Bool>(initialState: true)

    // Install POSIX signal handlers (SIGTERM / SIGINT) for graceful shutdown on logout or launchctl bootout
    DaemonSignalHandler.shared.install { @MainActor sig in
        AppLog.info(.app, "💾 Flushing SwiftData context and stopping daemon routines for signal \(sig)...")
        try? mainContext?.save()
        RoutineManager.shared.stopScheduledRoutines()
        server.stop()
        isRunning.withLock { $0 = false }
    }

    do {
        try server.start()
        AppLog.info(.app, "🚀 ApexGatewayServer started on port 1337")
        try? await Task.sleep(for: .seconds(1))
        while isRunning.withLock({ $0 }) {
            try? await Task.sleep(for: .seconds(1))
        }
        AppLog.info(.app, "🏁 Graceful daemon shutdown complete.")
    } catch {
        AppLog.error(.app, "⚠️ Failed to start daemon server: \(error)")
        exit(1)
    }
}

@MainActor
public func runSpaceCLIMode(subcommandArgs: [String]) async {
    let printOut: (String) -> Void = { msg in
        fputs("\(msg)\n", Darwin.stdout)
    }
    let printErr: (String) -> Void = { msg in
        fputs("\(msg)\n", Darwin.stderr)
    }

    AppLog.info(.app, "=== RUNNING SPACE CLI MODE ===")
    let orchestrator = AgentOrchestrator()
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self, SpacePageProposal.self)
        let mainContext = ModelContext(container)
        orchestrator.modelContext = mainContext
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        botManager.modelContext = mainContext
        botManager.loadBotsFromDisk()
        SpaceManager.shared.modelContext = mainContext
        SpaceManager.shared.orchestrator = orchestrator
        SpaceManager.shared.botManager = botManager
        SpaceManager.shared.loadSpacesFromDisk()
    } catch {
        AppLog.error(.app, "⚠️ Failed to initialize SwiftData model context: \(error). Falling back to resilient container.")
        if let fallback = try? SpaceModelMigrationGate.buildResilientModelContainer(inMemory: true) {
            let context = ModelContext(fallback)
            orchestrator.modelContext = context
            let computer = Computer()
            let botManager = BotManager(orchestrator: orchestrator, computer: computer)
            orchestrator.botManager = botManager
            botManager.modelContext = context
            botManager.loadBotsFromDisk()
            SpaceManager.shared.modelContext = context
            SpaceManager.shared.orchestrator = orchestrator
            SpaceManager.shared.botManager = botManager
            SpaceManager.shared.loadSpacesFromDisk()
        }
    }

    if subcommandArgs.isEmpty || subcommandArgs.contains("list") {
        printOut("Spaces (\(SpaceManager.shared.spaces.count)):")
        for space in SpaceManager.shared.spaces {
            printOut("- \(space.name) (ID: \(space.id), Workspace: \(space.workspacePath), Channels: \(space.channels.count), Humans: \(space.humanParticipants.count), Bots: \(space.agentParticipants.count))")
        }
    } else if let createIdx = subcommandArgs.firstIndex(of: "create"), createIdx + 1 < subcommandArgs.count {
        let name = subcommandArgs[createIdx + 1]
        var wsPath: String? = nil
        if let wsIdx = subcommandArgs.firstIndex(of: "--workspace"), wsIdx + 1 < subcommandArgs.count {
            wsPath = subcommandArgs[wsIdx + 1]
        }
        let space = SpaceManager.shared.createSpace(name: name, workspacePath: wsPath)
        printOut("Created Space '\(space.name)' (ID: \(space.id), Workspace: \(space.workspacePath))")
    } else if let memIdx = subcommandArgs.firstIndex(of: "memory"), memIdx + 1 < subcommandArgs.count {
        let spaceName = subcommandArgs[memIdx + 1]
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        if let setIdx = subcommandArgs.firstIndex(of: "--set"), setIdx + 1 < subcommandArgs.count {
            let newContent = subcommandArgs[(setIdx + 1)...].joined(separator: " ")
            try? SpaceMemoryTierManager.shared.saveCuratedMemory(newContent, for: space)
            printOut("Updated MEMORY.md for '\(space.name)':\n\(newContent)")
        } else {
            let content = SpaceMemoryTierManager.shared.loadCuratedMemory(for: space) ?? "(empty)"
            printOut("MEMORY.md for '\(space.name)' (\(space.memoryFilePath)):\n\(content)")
        }
    } else if let personaIdx = subcommandArgs.firstIndex(of: "persona"), personaIdx + 1 < subcommandArgs.count {
        let spaceName = subcommandArgs[personaIdx + 1]
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        if let setIdx = subcommandArgs.firstIndex(of: "--set"), setIdx + 1 < subcommandArgs.count {
            let newContent = subcommandArgs[(setIdx + 1)...].joined(separator: " ")
            try? SpaceMemoryTierManager.shared.savePersona(newContent, for: space)
            printOut("Updated PERSONA.md for '\(space.name)':\n\(newContent)")
        } else {
            let content = SpaceMemoryTierManager.shared.loadPersona(for: space) ?? "(empty)"
            printOut("PERSONA.md for '\(space.name)' (\(space.personaFilePath)):\n\(content)")
        }
    } else if let userIdx = subcommandArgs.firstIndex(of: "user"), userIdx + 1 < subcommandArgs.count {
        let spaceName = subcommandArgs[userIdx + 1]
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        if let setIdx = subcommandArgs.firstIndex(of: "--set"), setIdx + 1 < subcommandArgs.count {
            let newContent = subcommandArgs[(setIdx + 1)...].joined(separator: " ")
            try? SpaceMemoryTierManager.shared.saveUserContext(newContent, for: space)
            printOut("Updated USER.md for '\(space.name)':\n\(newContent)")
        } else {
            let content = SpaceMemoryTierManager.shared.loadUserContext(for: space) ?? "(empty)"
            printOut("USER.md for '\(space.name)' (\(space.userFilePath)):\n\(content)")
        }
    } else if let noteIdx = subcommandArgs.firstIndex(of: "note"), noteIdx + 2 < subcommandArgs.count {
        let spaceName = subcommandArgs[noteIdx + 1]
        let dateStr = subcommandArgs[noteIdx + 2]
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        if let setIdx = subcommandArgs.firstIndex(of: "--set"), setIdx + 1 < subcommandArgs.count {
            let newContent = subcommandArgs[(setIdx + 1)...].joined(separator: " ")
            _ = try? SpaceMemoryTierManager.shared.saveDailyNote(date: dateStr, content: newContent, space: space)
            printOut("Saved daily note \(dateStr) for '\(space.name)':\n\(newContent)")
        } else {
            let content = SpaceMemoryTierManager.shared.getDailyNote(date: dateStr, space: space) ?? "(not found)"
            printOut("Daily note \(dateStr) for '\(space.name)':\n\(content)")
        }
    } else if let notesIdx = subcommandArgs.firstIndex(of: "notes"), notesIdx + 1 < subcommandArgs.count {
        let spaceName = subcommandArgs[notesIdx + 1]
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        let query = (notesIdx + 2 < subcommandArgs.count) ? subcommandArgs[(notesIdx + 2)...].joined(separator: " ") : ""
        let results = SpaceMemoryTierManager.shared.searchDailyNotes(query: query, space: space)
        printOut("Daily notes in '\(space.name)' (query: '\(query)', matches: \(results.count)):")
        for match in results {
            printOut("- [\(match.date)] \(match.title) (score: \(String(format: "%.1f", match.score)))\n  Snippet: \(match.snippet)")
        }
    } else if let runIdx = subcommandArgs.firstIndex(of: "run"), runIdx + 2 < subcommandArgs.count {
        let spaceName = subcommandArgs[runIdx + 1]
        let promptText = subcommandArgs[(runIdx + 2)...].joined(separator: " ")
        guard let space = SpaceManager.shared.spaces.first(where: {
            $0.name.localizedCaseInsensitiveCompare(spaceName) == .orderedSame || $0.id.uuidString.hasPrefix(spaceName)
        }) else {
            printErr("Space '\(spaceName)' not found.")
            return
        }
        SpaceManager.shared.selectSpace(space)
        printOut("Running live turn in Space '\(space.name)'...")
        printOut("Prompt: \(promptText)")
        if let reply = await SpaceManager.shared.runTurnAndWait(prompt: promptText, in: space) {
            printOut("\n=== AGENT RESPONSE [\(reply.senderName)] ===")
            printOut(reply.content)
            printOut("===========================================")
        } else {
            printErr("No response generated from agent.")
        }
    } else if let postIdx = subcommandArgs.firstIndex(of: "post"), postIdx + 2 < subcommandArgs.count {
        let channelName = subcommandArgs[postIdx + 1]
        let messageText = subcommandArgs[postIdx + 2]
        if let space = SpaceManager.shared.spaces.first,
           let channel = space.channels.first(where: { $0.name == channelName }) ?? space.channels.first {
            _ = SpaceManager.shared.postHumanMessage(messageText, in: channel)
            printOut("Posted message to #\(channel.name): \(messageText)")
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
