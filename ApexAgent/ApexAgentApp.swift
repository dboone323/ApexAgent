import AppKit
import Carbon
import CoreSpotlight
import Foundation
import FoundationModels
import Intents
import SwiftData
import SwiftUI
import SharedKit

@MainActor
public struct ApexAgentApp: App {
    let orchestrator = AppDelegate.sharedOrchestrator
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var botManager: BotManager
    @State private var spaceManager = SpaceManager.shared
    let computer: Computer
    @State private var skillManager = SkillManager.shared
    @State private var routineManager = RoutineManager.shared

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
                .environment(skillManager)
                .environment(routineManager)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    GlobalCommandPaletteController.shared.registerHotKey()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .modelContainer(for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self])
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    botManager.activeBotId = nil
                    spaceManager.activeSpaceId = nil
                    orchestrator.startNewConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(replacing: .help) {
                Button("Apex Agent Documentation & Guide") {
                    if let url = URL(string: "https://github.com/dboone323/ApexAgent#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }
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
                .environment(skillManager)
                .environment(routineManager)
                .modelContainer(for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self])
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
        setupStatusItem()
        setupGlobalHotkey()
        setupShortcuts()
        setupSpotlight()
        Task.detached(priority: .utility) {
            Self.checkFMCLIAvailability()
        }
        startWebhookReceiverIfPossible()
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
            print("WebhookServer: port 1338 unavailable (daemon may be running): \(error)")
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
    public static func runCLIMode(prompt: String) async {
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        print("=== RUNNING CLI TEST ===")
        print("Prompt: \(prompt)")

        let orchestrator = AgentOrchestrator()
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager

        do {
            let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
            let mainContext = ModelContext(container)
            orchestrator.modelContext = mainContext
            botManager.modelContext = mainContext
            botManager.loadBotsFromDisk()
            if let url = container.configurations.first?.url {
                print("🧠 SwiftData Store URL: \(url.path)")
            }
        } catch {
            print("⚠️ Failed to initialize SwiftData model context: \(error)")
        }

        orchestrator.autoApproveToolCalls = true
        if let perms = orchestrator.permissions {
            perms.desktopFolderAllowed = true
            perms.documentsFolderAllowed = true
            perms.downloadsFolderAllowed = true
            perms.musicFolderAllowed = true
            try? orchestrator.modelContext?.save()
        }
        try? await Task.sleep(for: .seconds(1))

        await orchestrator.sendMessageAndWait(prompt)

        print("\n=== TOOL EVENTS ===")
        if orchestrator.toolEvents.isEmpty {
            print("No tools called.")
        } else {
            for event in orchestrator.toolEvents.reversed() {
                print("Tool: \(event.toolName)")
                print("Args: \(event.arguments)")
                print("Result: \(event.result ?? "nil")")
                print("Status: \(event.status)")
                print("-------------------")
            }
        }

        print("\n=== FINAL RESPONSE ===")
        if let lastMessage = orchestrator.messages.last(where: { $0.role == .assistant }) {
            print(lastMessage.content)
        } else {
            print("No response received")
        }
        print("=======================")
    }
}

@MainActor
public func runDaemonMode() async {
    print("=== RUNNING DAEMON MODE ===")
    let orchestrator = AgentOrchestrator()
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
        let mainContext = ModelContext(container)
        orchestrator.modelContext = mainContext
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        botManager.modelContext = mainContext
        botManager.loadBotsFromDisk()
        RoutineManager.shared.modelContext = mainContext
        RoutineManager.shared.botManager = botManager
        RoutineManager.shared.loadRoutines()
        RoutineManager.shared.startScheduledRoutines()
        if let url = container.configurations.first?.url {
            print("🧠 SwiftData Store URL: \(url.path)")
        }
    } catch {
        print("⚠️ Failed to initialize SwiftData model context: \(error)")
    }

    let server = ApexGatewayServer(port: 1337, orchestrator: orchestrator)
    do {
        try server.start()
        print("🚀 ApexGatewayServer started on port 1337")
        try? await Task.sleep(for: .seconds(1))
        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    } catch {
        print("⚠️ Failed to start daemon server: \(error)")
        exit(1)
    }
}

@MainActor
public func runSpaceCLIMode(subcommandArgs: [String]) async {
    print("=== RUNNING SPACE CLI MODE ===")
    let orchestrator = AgentOrchestrator()
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
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
        print("⚠️ Failed to initialize SwiftData model context: \(error)")
    }

    if subcommandArgs.isEmpty || subcommandArgs.contains("list") {
        print("Spaces (\(SpaceManager.shared.spaces.count)):")
        for space in SpaceManager.shared.spaces {
            print("- \(space.name) (ID: \(space.id), Channels: \(space.channels.count), Humans: \(space.humanParticipants.count), Bots: \(space.agentParticipants.count))")
        }
    } else if let postIdx = subcommandArgs.firstIndex(of: "post"), postIdx + 2 < subcommandArgs.count {
        let channelName = subcommandArgs[postIdx + 1]
        let messageText = subcommandArgs[postIdx + 2]
        if let space = SpaceManager.shared.spaces.first,
           let channel = space.channels.first(where: { $0.name == channelName }) ?? space.channels.first {
            _ = SpaceManager.shared.postHumanMessage(messageText, in: channel)
            print("Posted message to #\(channel.name): \(messageText)")
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
