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
        ContainerBridge.shared = ContainerManager.shared
        let args = CommandLine.arguments
        if args.contains("--daemon") {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await runDaemonMode()
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        }

        if let cliIndex = args.firstIndex(of: "--cli"), cliIndex + 1 < args.count {
            let prompt = args[cliIndex + 1]
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await AppDelegate.runCLIMode(prompt: prompt)
                semaphore.signal()
            }
            semaphore.wait()
            exit(0)
        } else {
            // Attempt to connect to background daemon gateway. Deferred to a
            // separate task so the resulting observable state mutation
            // (connect -> refused -> isConnected=false) does not race the
            // app's initial view-update transaction ("Publishing changes from
            // within view updates"). The gateway server is a separate process
            // the app does not auto-start, so a refused connection is expected
            // and handled by ApexGatewayClient's capped retry.
            Task { @MainActor in
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
class AppDelegate: NSObject, NSApplicationDelegate, OrchestratorProvider {
    static var sharedOrchestrator = AgentOrchestrator()
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

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        process.arguments = ["version"]
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
            // Donate the ApexAgent App Intents to Siri / Shortcuts.
            ApexAgentShortcuts.updateAppShortcutParameters()
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
        let hotKeyID = EventHotKeyID(signature: 0x41504558, id: 1) // "APEX"
        var hotKeyRef: EventHotKeyRef?
        let optionModifier = UInt32(optionKey)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerUPP: EventHandlerUPP = { nextHandler, event, userData in
            DispatchQueue.main.async {
                if let delegate = NSApplication.shared.delegate as? AppDelegate {
                    delegate.toggleQuickPrompt()
                }
            }
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), handlerUPP, 1, &eventType, nil, nil)
        RegisterEventHotKey(49, optionModifier, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func toggleQuickPrompt() {
        if quickPromptPanel == nil {
            let orchestrator = self.orchestrator
            quickPromptPanel = QuickPromptPanel(orchestrator: orchestrator)
        }

        guard let panel = quickPromptPanel else { return }

        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @MainActor
    fileprivate static func runCLIMode(prompt: String) async {
        print("=== RUNNING CLI TEST ===")
        print("Prompt: \(prompt)")

        let orchestrator = AgentOrchestrator()
        do {
            let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self)
            orchestrator.modelContext = ModelContext(container)
            if let url = container.configurations.first?.url {
                print("🧠 SwiftData Store URL: \(url.path)")
            }
        } catch {
            print("⚠️ Failed to initialize SwiftData model context: \(error)")
        }

        // Wait a brief moment to ensure SystemLanguageModel is ready/loaded
        try? await Task.sleep(for: .seconds(2))

        orchestrator.sendMessage(prompt)

        // Wait for generation to start and then complete
        try? await Task.sleep(for: .milliseconds(500))
        while orchestrator.isGenerating {
            try? await Task.sleep(for: .milliseconds(100))
        }

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
private func runDaemonMode() async {
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
