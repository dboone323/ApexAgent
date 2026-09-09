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
    let computer: Computer
    @State private var skillManager = SkillManager()
    @State private var routineManager = RoutineManager()

    public init() {
        self.computer = Computer()
        self.botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        ContainerBridge.shared = ContainerManager.shared
        let args = CommandLine.arguments
        // Attempt to connect to background daemon gateway if explicitly requested or reachable.
            // Probing reachability avoids Network.framework ECONNREFUSED socket error noise when
            // running in standalone GUI mode without the daemon.
            Task { @MainActor in
                let shouldConnect = UserDefaults.standard.bool(forKey: "apex.connectGateway")
                    || ProcessInfo.processInfo.arguments.contains("--connect-gateway")
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
                .environment(computer)
                .environment(\.groupChatManager, GroupChatManager())
                .environment(skillManager)
                .environment(routineManager)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    GlobalCommandPaletteController.shared.registerHotKey()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .modelContainer(for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self])
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    orchestrator.startNewConversation()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
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
    var quickPromptPanel: QuickPromptPanel?
    private var webhookServer: WebhookServer?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalHotkey()
        setupShortcuts()
        setupSpotlight()
        checkFMCLIAvailability()
        startWebhookReceiverIfPossible()
    }

    /// O5: serve .webhook routines while the GUI runs. If the port is taken
    /// (e.g. the daemon is already bound), its receiver covers us — non-fatal.
    private func startWebhookReceiverIfPossible() {
        let server = WebhookServer(manager: WebhookManager())
        server.onAccepted = { routineName, _, _, _ in
            Task { @MainActor in
                _ = await RoutineManager.shared.dispatchWebhook(routineName: routineName)
            }
        }
        do {
            try server.start(preferredPort: 8800)
            webhookServer = server
            RoutineManager.shared.loadRoutines()
        } catch {
            print("ℹ️ Webhook receiver not started: \(error.localizedDescription)")
        }
    }

    /// On macOS 27 the on-device FoundationModel + App Intents depend on `/usr/bin/fm`.
    /// If the CLI is missing (non-Apple Silicon, build without FM, or `sudo fm license` not
    /// accepted), surface a one-shot warning so the user isn't left with silent failures when
    /// they try to use on-device model features.
    private func checkFMCLIAvailability() {
        let fmPath = "/usr/bin/fm"
        guard FileManager.default.fileExists(atPath: fmPath) else {
            print("[Apex] WARNING: /usr/bin/fm not found — on-device FoundationModel + App Intents will be unavailable. Run `sudo fm license` to enable Apple's on-device model.")
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
            if process.terminationStatus != 0 {
                print("[Apex] WARNING: /usr/bin/fm exists but is not licensed/functional (exit \(process.terminationStatus)). Run `sudo fm license` to enable Apple's on-device model.")
            } else {
                print("[Apex] FoundationModels CLI (/usr/bin/fm) is available.")
            }
        } catch {
            print("[Apex] WARNING: could not probe /usr/bin/fm: \(error.localizedDescription)")
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Apex Agent")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Apex", action: #selector(showMainWindow), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Diagnostics Check", action: #selector(showDiagnostics), keyEquivalent: "d"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Apex", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { !$0.isKind(of: NSPanel.self) }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func showDiagnostics() {
        showMainWindow()
        NotificationCenter.default.post(name: .showDiagnosticsSheet, object: nil)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func setupShortcuts() {
        if #available(macOS 13.0, *) {
            // AppShortcut registration with linkd requires a valid installed app bundle with CFBundleIdentifier.
            // When running headless in tests, CLI mode, or unbundled debug builds, linkd rejects the XPC service connection (Cocoa error 4097).
            let isAppBundle = Bundle.main.bundleURL.pathExtension == "app"
            let isTestOrCLI = ProcessInfo.processInfo.arguments.contains { $0.contains("test") || $0.contains("xctest") || $0 == "--cli" || $0 == "-c" } || ProcessInfo.processInfo.environment["APEX_TEST_MODE"] == "1"
            guard isAppBundle && !isTestOrCLI else { return }

            // Donate the ApexAgent App Intents to Siri / Shortcuts asynchronously once launch completes
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(2))
                ApexAgentShortcuts.updateAppShortcutParameters()
            }
        } else {
            print("[Apex] Shortcut setup skipped: macOS 13+ required for App Intents integration.")
        }
    }

    private func setupSpotlight() {
        let activity = NSUserActivity(activityType: "com.dboone323.ApexAgent.query")
        activity.title = "Ask Apex Agent"
        activity.isEligibleForSearch = true
        activity.userInfo = ["entry": "spotlight"]
        activity.becomeCurrent()
    }

    private func setupGlobalHotkey() {
        GlobalCommandPaletteController.shared.registerHotKey()
    }

    func toggleQuickPrompt() {
        GlobalCommandPaletteController.shared.toggle()
    }

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
            let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self)
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
        // Wait a brief moment to ensure SystemLanguageModel is ready/loaded
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
        exit(0)
    }
}

@MainActor
public func runDaemonMode() async {
    print("=== RUNNING DAEMON MODE ===")
    let orchestrator = AgentOrchestrator()
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self)
        let mainContext = ModelContext(container)
        orchestrator.modelContext = mainContext
        if let url = container.configurations.first?.url {
            print("🧠 SwiftData Store URL: \(url.path)")
        }

        // WS3: the daemon owns bots + routines so scheduled/webhook work
        // keeps running while the GUI is closed.
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager
        botManager.modelContext = mainContext
        botManager.loadBotsFromDisk()
        RoutineManager.shared.modelContext = mainContext
        RoutineManager.shared.botManager = botManager
        RoutineManager.shared.loadRoutines()
        RoutineManager.shared.startScheduledRoutines()
        print("🤖 Daemon bots: \(botManager.allBots.count), routines: \(RoutineManager.shared.routines.count)")
    } catch {
        print("⚠️ Failed to initialize SwiftData model context: \(error)")
    }

    let server = ApexGatewayServer(port: 1337, orchestrator: orchestrator)
    do {
        try server.start()

        // O5: localhost webhook receiver so .webhook routines fire externally.
        let webhooks = WebhookServer(manager: WebhookManager())
        webhooks.onAccepted = { routineName, _, _, _ in
            Task { @MainActor in
                _ = await RoutineManager.shared.dispatchWebhook(routineName: routineName)
            }
        }
        do {
            try webhooks.start(preferredPort: 8800)
            print("🪝 Webhook receiver: http://127.0.0.1:\(webhooks.port)/hooks/<endpoint>")
        } catch {
            // Port busy (e.g. the GUI app is already running its own receiver):
            // non-fatal, the gateway above still serves.
            print("⚠️ Webhook receiver unavailable: \(error.localizedDescription)")
        }

        // Wait a brief moment to ensure SystemLanguageModel is ready/loaded
        try? await Task.sleep(for: .seconds(2))

        while true {
            try? await Task.sleep(for: .seconds(3600))
        }
    } catch {
        print("⚠️ Failed to start daemon server: \(error)")
        exit(1)
    }
}

public class WritingToolsSupportLoader: NSObject {
    @MainActor
    static func configureWritingTools() {
        WritingToolsSupport.register()
    }
}
