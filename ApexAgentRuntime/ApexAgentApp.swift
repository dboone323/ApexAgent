import AppKit
import Carbon
import CoreSpotlight
import Foundation
import FoundationModels
import Intents
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import SharedKit
import ApexAgentContainer
@testable import ApexAgentCore

@main
@MainActor
struct ApexAgentApp: App {
    private let orchestrator = AppDelegate.sharedOrchestrator
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
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
            // Attempt to connect to background daemon gateway
            ApexGatewayClient.shared.connect()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(orchestrator)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .modelContainer(for: [Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self])
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
    var statusItem: NSStatusItem?
    var quickPromptPanel: QuickPromptPanel?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupGlobalHotkey()
        setupShortcuts()
        setupSpotlight()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Apex Agent")
        }
        
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Apex", action: #selector(showMainWindow), keyEquivalent: "a"))
        menu.addItem(NSMenuItem(title: "Diagnostics Check", action: #selector(showDiagnostics), keyEquivalent: "d"))
        menu.addItem(NSMenuItem.separator())
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
        #if DEBUG
        let installHint = "You can define this in an Intent Definition File and wire it to Shortcuts."
        #else
        let installHint = "Shortcuts integration is not configured in release builds."
        #endif
        let intent = WriteTextIntent()
        intent.suggestedInvocationPhrase = "Write with Apex Agent"
        if #available(macOS 13.0, *) {
            guard let shortcut = INShortcut(intent: intent) else {
                print("[Apex] Shortcut setup skipped: unable to initialize INShortcut. \(installHint)")
                return
            }
            INVoiceShortcutCenter.shared.setShortcutSuggestions([shortcut])
        } else {
            print("[Apex] Shortcut setup skipped: macOS 13+ required for this integration.")
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
        ProcessInfo.processInfo.setValue("1", forKey: "APEX_TEST_MODE")

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
        let container = try ModelContainer(for: Conversation.self, Message.self, AgentMemory.self, AppPermissions.self, ProjectModel.self, TaskModel.self, SprintModel.self, CodeIssueModel.self, ReviewSession.self)
        orchestrator.modelContext = ModelContext(container)
        if let url = container.configurations.first?.url {
            print("🧠 SwiftData Store URL: \(url.path)")
        }
    } catch {
        print("⚠️ Failed to initialize SwiftData model context: \(error)")
    }
    
    let server = ApexGatewayServer(port: 1337, orchestrator: orchestrator)
    do {
        try server.start()
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

public class WriteTextIntent: INIntent {}

extension AppDelegate {
    static func configureWritingTools() {
        WritingToolsSupport.register()
    }
}

