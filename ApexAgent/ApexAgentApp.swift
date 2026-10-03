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
    nonisolated static func checkFMCLIAvailability() {
        let fmPath = "/usr/bin/fm"
        guard FileManager.default.fileExists(atPath: fmPath) else {
            print("[Apex] WARNING: /usr/bin/fm not found — on-device FoundationModel + App Intents will be unavailable. Run `sudo fm license` to enable Apple's on-device model.")
            return
        }
        // Probe that `fm` actually responds (it is gated behind `sudo fm license` on macOS 27).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: fmPath)
        process.arguments = ["models"]
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
        let activity = NSUserActivity(activityType: "com.apexagent.ApexAgent.query")
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
        let activeProvider = ModelRegistry.activeProvider()
        print("=== RUNNING CLI TEST ===")
        print("Provider: \(activeProvider.rawValue) (\(activeProvider.displayName))")
        if activeProvider == .localOllama {
            print("Ollama Model: \(ModelRegistry.ollamaModel())")
        } else if activeProvider == .cloudGemini {
            print("Gemini Model: \(ModelRegistry.geminiModel())")
        }
        print("Prompt: \(prompt)")

        AgentRequestRouter.shared.addEventListener { event in
            switch event {
            case .providerSelected(let provider, let reason):
                print("🎯 [Provider Selected]: \(provider.rawValue) — \(reason ?? "primary")")
            case .providerFallback(let from, let to, let error):
                print("🔄 [Provider Fallback]: \(from.rawValue) -> \(to.rawValue) (reason: \(error))")
            default:
                break
            }
        }

        let orchestrator = AppDelegate.sharedOrchestrator
        MCPManager.shared.orchestrator = orchestrator
        DynamicToolbox.shared.orchestrator = orchestrator
        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        orchestrator.botManager = botManager

        do {
            let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
            let mainContext = ModelContext(container)
            orchestrator.modelContext = mainContext
            botManager.modelContext = mainContext
            botManager.loadBotsFromDisk()
            SpaceManager.shared.orchestrator = orchestrator
            SpaceManager.shared.botManager = botManager
            SpaceManager.shared.modelContext = mainContext
            SpaceManager.shared.loadSpacesFromDisk()
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
        let assistantMessages = orchestrator.messages.filter { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if assistantMessages.isEmpty {
            print("No response received")
        } else {
            for (idx, msg) in assistantMessages.enumerated() {
                if idx > 0 {
                    print("\n---")
                }
                print(msg.content)
            }
        }
        print("=======================")
        await MCPManager.shared.stopAll()
        exit(0)
    }
}

@MainActor
public func runDaemonMode() async {
    print("=== RUNNING DAEMON MODE ===")
    let orchestrator = AppDelegate.sharedOrchestrator
    MCPManager.shared.orchestrator = orchestrator
    DynamicToolbox.shared.orchestrator = orchestrator
    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
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
        SpaceManager.shared.orchestrator = orchestrator
        SpaceManager.shared.botManager = botManager
        SpaceManager.shared.modelContext = mainContext
        SpaceManager.shared.loadSpacesFromDisk()
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

@MainActor
public func runSpaceCLIMode(subcommandArgs: [String]) async {
    setbuf(stdout, nil)
    setbuf(stderr, nil)

    let orchestrator = AppDelegate.sharedOrchestrator
    MCPManager.shared.orchestrator = orchestrator
    DynamicToolbox.shared.orchestrator = orchestrator
    let computer = Computer()
    let botManager = BotManager(orchestrator: orchestrator, computer: computer)
    orchestrator.botManager = botManager

    let spaceManager = SpaceManager.shared
    spaceManager.orchestrator = orchestrator
    spaceManager.botManager = botManager

    do {
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self, Skill.self, Routine.self, BotProfile.self, SpaceModel.self, SpaceParticipant.self, SpaceChannel.self, SpaceMessage.self, SpacePage.self)
        let mainContext = ModelContext(container)
        orchestrator.modelContext = mainContext
        botManager.modelContext = mainContext
        botManager.loadBotsFromDisk()
        spaceManager.modelContext = mainContext
        spaceManager.loadSpacesFromDisk()
    } catch {
        print("⚠️ Failed to initialize SwiftData model context: \(error)")
        exit(1)
    }

    guard let space = spaceManager.activeSpace else {
        print("❌ No active Space found.")
        exit(1)
    }

    let subcommand = subcommandArgs.first ?? "status"

    switch subcommand {
    case "status":
        print("=== APEX SPACES STATUS ===")
        for sp in spaceManager.spaces {
            print("Space: \(sp.name) [id: \(sp.id.uuidString)]")
            print("  Mode: \(sp.orchestrationMode.displayName)")
            print("  Workspace: \(sp.workspacePath)")
            print("  Invite URL: \(spaceManager.inviteURL(for: sp))")
            print("  Humans (\(sp.humanParticipants.count)):")
            for h in sp.humanParticipants {
                print("    - \(h.displayName) (@\(h.handle)) [\(h.role.badgeLabel) • \(h.roleTitle)]")
            }
            print("  AI Agents (\(sp.agentParticipants.count)):")
            for a in sp.agentParticipants {
                print("    - \(a.displayName) (@\(a.handle)) [\(a.roleTitle)]")
            }
            print("  Channels (\(sp.sortedChannels.count)):")
            for ch in sp.sortedChannels {
                print("    - #\(ch.name) (\(ch.rootMessages.count) root msgs): \(ch.topic)")
            }
            print("  Shared Pages (\(sp.sortedPages.count)):")
            for pg in space.sortedPages {
                print("    - \(pg.title) (edited by \(pg.lastEditedByName))")
            }
        }

    case "add-human":
        let name = subcommandArgs.count > 1 ? subcommandArgs[1] : "Alex Rivera"
        let handle = subcommandArgs.count > 2 ? subcommandArgs[2] : nil
        let roleTitle = subcommandArgs.count > 3 ? subcommandArgs[3] : "Staff Engineer"
        let participant = spaceManager.addHumanParticipant(
            to: space,
            displayName: name,
            handle: handle,
            roleTitle: roleTitle,
            role: .member,
            isRemote: true
        )
        print("✅ Added Human Participant: \(participant.displayName) (@\(participant.handle)) — \(participant.roleTitle)")
        print("Total Humans in '\(space.name)': \(space.humanParticipants.count)")

    case "page":
        let title = subcommandArgs.count > 1 ? subcommandArgs[1] : "Architecture Decision Record"
        let body = subcommandArgs.count > 2 ? subcommandArgs[2] : "## Context\nShared via Apex Spaces CLI."
        let page = spaceManager.createPage(
            in: space,
            title: title,
            markdownBody: body,
            authorName: spaceManager.activeHumanSender?.displayName ?? "CLI User"
        )
        print("✅ Created Shared SpacePage: '\(page.title)' [id: \(page.id.uuidString)]")
        print(page.markdownBody)

    case "post":
        let channelName = subcommandArgs.count > 1 ? SpaceChannel.normalizeChannelName(subcommandArgs[1]) : "general"
        let senderHandle = subcommandArgs.count > 2 ? SpaceParticipant.normalizeHandle(subcommandArgs[2]) : (spaceManager.activeHumanSender?.handle ?? "owner")
        let content = subcommandArgs.count > 3 ? subcommandArgs.dropFirst(3).joined(separator: " ") : "Hello @apex!"

        let channel = space.channels.first(where: { $0.name == channelName }) ?? spaceManager.addChannel(to: space, name: channelName)
        let sender = space.humanParticipants.first(where: { $0.handle == senderHandle })
            ?? spaceManager.addHumanParticipant(to: space, displayName: senderHandle.capitalized, handle: senderHandle)

        // Post without background fire-and-forget so we can await the real bot turns deterministically in CLI
        guard let msg = spaceManager.postHumanMessage(content, in: channel, sender: sender, triggerAgents: false) else {
            print("❌ Failed to post message.")
            exit(1)
        }
        print("💬 [HUMAN • \(msg.senderName) (@\(msg.senderHandle)) in #\(channel.name)]: \(msg.content)")

        let targetBots = spaceManager.resolveTargetBots(
            for: content,
            in: space,
            channel: channel,
            senderKind: .human
        )
        if targetBots.isEmpty {
            print("🔇 [Orchestration Engine]: 0 bots triggered (Human-to-Human passive listener mode).")
        } else {
            print("🤖 [Orchestration Engine]: Dispatching live turn(s) to: \(targetBots.map { "\($0.name) (@\(SpaceParticipant.normalizeHandle($0.name)))" }.joined(separator: ", "))")
            await spaceManager.dispatchBotTurns(
                bots: targetBots,
                in: space,
                channel: channel,
                triggerMessage: msg,
                parallel: space.orchestrationMode == .parallelSwarm && targetBots.count > 1
            )
            let botReplies = channel.rootMessages.suffix(targetBots.count)
            for reply in botReplies where reply.senderKind == .bot {
                print("🤖 [AGENT • \(reply.senderName) (@\(reply.senderHandle)) in #\(channel.name)]:\n\(reply.content)\n")
            }
        }

    case "serve-test":
        print("🌐 Starting CollaborativeServer on ephemeral localhost port for live HTTP verification...")
        CollaborativeServer.shared.start(port: 0)
        // Wait up to 2s for NWListener to report ready and assign port
        for _ in 0..<20 {
            if CollaborativeServer.shared.isRunning && CollaborativeServer.shared.port != 0 && CollaborativeServer.shared.port != 1340 {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let port = CollaborativeServer.shared.port
        print("✅ CollaborativeServer listening on http://127.0.0.1:\(port)")

        let general = space.sortedChannels.first!
        let ownerHandle = space.humanParticipants.first?.handle ?? "owner"
        let postURL = URL(string: "http://127.0.0.1:\(port)/api/spaces/message")!
        var postReq = URLRequest(url: postURL)
        postReq.httpMethod = "POST"
        postReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload = SpaceMessagePostPayload(
            spaceId: space.id,
            channelId: general.id,
            senderName: "Elena Vance",
            senderHandle: "elena",
            content: "Hey @\(ownerHandle), posting live over HTTP into #\(general.name)!"
        )
        postReq.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (postData, postResp) = try await URLSession.shared.data(for: postReq)
            let statusCode = (postResp as? HTTPURLResponse)?.statusCode ?? 0
            print("📤 POST /api/spaces/message -> HTTP \(statusCode): \(String(decoding: postData, as: UTF8.self))")

            let getURL = URL(string: "http://127.0.0.1:\(port)/api/spaces")!
            let (getData, getResp) = try await URLSession.shared.data(from: getURL)
            let getStatus = (getResp as? HTTPURLResponse)?.statusCode ?? 0
            let snapshots = try JSONDecoder().decode([SpaceSnapshotDTO].self, from: getData)
            print("📥 GET /api/spaces -> HTTP \(getStatus) (decoded \(snapshots.count) Space snapshot(s))")
            if let first = snapshots.first {
                print("   Space: \(first.name) | Participants: \(first.participants.count) | Channels: \(first.channels.count) | Pages: \(first.pages.count)")
                if let genDTO = first.channels.first(where: { $0.name == general.name }),
                   let lastMsg = genDTO.messages.last {
                    print("   Latest Message in #\(genDTO.name): [\(lastMsg.senderName) (@\(lastMsg.senderHandle))]: \(lastMsg.content)")
                }
            }
        } catch {
            print("❌ HTTP verification failed: \(error)")
            CollaborativeServer.shared.stop()
            exit(1)
        }
        CollaborativeServer.shared.stop()

    default:
        print("Unknown --space-cli subcommand: \(subcommand)")
        exit(1)
    }
}
