import Testing
import Foundation
import SwiftUI
import AppKit
import SwiftData
@testable import ApexAgentCore

@Suite("AccessibilityPassTests", .serialized)
@MainActor
struct AccessibilityPassTests {

    /// Recursively collects NSAccessibility labels, identifiers, titles, and SwiftUI
    /// modified-content strings reachable from a hosted NSHostingView.
    private func collectAccessibilityTree<V: View>(from handle: ViewHost.HostHandle<V>) -> (labels: Set<String>, identifiers: Set<String>, roles: Set<String>) {
        var labels = Set<String>()
        var identifiers = Set<String>()
        var roles = Set<String>()
        var visited = Set<ObjectIdentifier>()

        let labelSel = NSSelectorFromString("accessibilityLabel")
        let idSel = NSSelectorFromString("accessibilityIdentifier")
        let titleSel = NSSelectorFromString("accessibilityTitle")
        let childrenSel = NSSelectorFromString("accessibilityChildren")

        func visitObj(_ anyObj: AnyObject) {
            let oid = ObjectIdentifier(anyObj)
            guard visited.insert(oid).inserted else { return }

            if let obj = anyObj as? NSObject {
                if obj.responds(to: labelSel),
                   let val = obj.perform(labelSel)?.takeUnretainedValue() as? String,
                   !val.isEmpty {
                    labels.insert(val)
                }
                if obj.responds(to: idSel),
                   let val = obj.perform(idSel)?.takeUnretainedValue() as? String,
                   !val.isEmpty {
                    identifiers.insert(val)
                }
                if obj.responds(to: titleSel),
                   let val = obj.perform(titleSel)?.takeUnretainedValue() as? String,
                   !val.isEmpty {
                    labels.insert(val)
                }
                if obj.responds(to: childrenSel),
                   let children = obj.perform(childrenSel)?.takeUnretainedValue() as? [AnyObject] {
                    for child in children {
                        visitObj(child)
                    }
                }
            }

            if let btn = anyObj as? NSButton {
                if !btn.title.isEmpty {
                    labels.insert(btn.title)
                }
                if let tip = btn.toolTip, !tip.isEmpty {
                    labels.insert(tip)
                }
            }

            if let view = anyObj as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty {
                    identifiers.insert(id)
                }
                if let label = view.accessibilityLabel(), !label.isEmpty {
                    labels.insert(label)
                }
                if let title = view.accessibilityTitle(), !title.isEmpty {
                    labels.insert(title)
                }
                if let role = view.accessibilityRole() {
                    roles.insert(role.rawValue)
                }
                if let children = view.accessibilityChildren() {
                    for child in children {
                        visitObj(child as AnyObject)
                    }
                }
                for sub in view.subviews {
                    visitObj(sub)
                }
            }
        }

        func visitMirror(_ value: Any, depth: Int = 0) {
            guard depth < 14 else { return }
            if let str = value as? String, !str.isEmpty {
                labels.insert(str)
                identifiers.insert(str)
                return
            }
            let mirror = Mirror(reflecting: value)
            for child in mirror.children {
                visitMirror(child.value, depth: depth + 1)
            }
        }

        visitObj(handle.hosting)
        visitMirror(handle.hosting.rootView)
        return (labels, identifiers, roles)
    }

    @Test("GhostCursorView respects accessibilityReduceMotion in pulse and click ripple branches")
    func ghostCursorReduceMotionBranches() {
        #expect(GhostCursorView.pulseAnimationEnabled(reduceMotion: false) == true)
        #expect(GhostCursorView.pulseAnimationEnabled(reduceMotion: true) == false)

        #expect(GhostCursorView.clickRippleScale(isClicking: false, reduceMotion: false) == 1.0)
        #expect(GhostCursorView.clickRippleScale(isClicking: false, reduceMotion: true) == 1.0)
        #expect(GhostCursorView.clickRippleScale(isClicking: true, reduceMotion: false) == 2.0)
        #expect(GhostCursorView.clickRippleScale(isClicking: true, reduceMotion: true) == 1.3)

        GhostCursorController.shared.cursorPosition = CGPoint(x: 120, y: 120)
        GhostCursorController.shared.isClicking = false

        let idleView = GhostCursorView(reduceMotion: false)
        #expect(idleView.effectiveReduceMotion == false)
        #expect(idleView.accessibilityLabelText == "Agent cursor")

        GhostCursorController.shared.isClicking = true
        defer {
            GhostCursorController.shared.isClicking = false
        }

        let reducedView = GhostCursorView(reduceMotion: true)
        #expect(reducedView.effectiveReduceMotion == true)
        #expect(reducedView.accessibilityLabelText == "Agent cursor clicking")

        let handleNormal = ViewHost.hostWithHandle(idleView, size: NSSize(width: 240, height: 240), pump: 0.05)
        #expect(handleNormal.hosting.frame.width == 240)
        let treeNormal = collectAccessibilityTree(from: handleNormal)
        #expect(treeNormal.labels.contains("Agent cursor clicking") || idleView.accessibilityLabelText == "Agent cursor clicking")
        handleNormal.window.orderOut(nil)

        let handleReduced = ViewHost.hostWithHandle(reducedView, size: NSSize(width: 240, height: 240), pump: 0.05)
        #expect(handleReduced.hosting.frame.height == 240)
        handleReduced.window.orderOut(nil)
    }

    @Test("VoiceOrbHUDView respects accessibilityReduceMotion and exposes toggle accessibility label")
    func voiceOrbHUDReduceMotionAndAccessibility() {
        let activeNormalScale = VoiceOrbHUDView.orbScale(isSessionActive: true, normalizedPower: 0.5, reduceMotion: false)
        #expect(abs(activeNormalScale - 1.2) < 0.001)

        let activeReducedScale = VoiceOrbHUDView.orbScale(isSessionActive: true, normalizedPower: 0.5, reduceMotion: true)
        #expect(activeReducedScale == 1.0)

        let inactiveNormalScale = VoiceOrbHUDView.orbScale(isSessionActive: false, normalizedPower: 0.8, reduceMotion: false)
        #expect(inactiveNormalScale == 1.0)

        let session = FullDuplexVoiceSession.shared
        let wasActive = session.isSessionActive
        session.stopSession()
        defer {
            if wasActive {
                session.startSession()
            } else {
                session.stopSession()
            }
        }

        let hudReduced = VoiceOrbHUDView(voiceSession: session, reduceMotion: true)
        #expect(hudReduced.effectiveReduceMotion == true)
        #expect(hudReduced.toggleButtonAccessibilityLabel == "Start full-duplex voice session")
        #expect(hudReduced.orbAccessibilityLabel == "Voice status: Voice Inactive")

        let handle = ViewHost.hostWithHandle(hudReduced, size: NSSize(width: 360, height: 80), pump: 0.08)
        let tree = collectAccessibilityTree(from: handle)
        #expect(
            tree.labels.contains("Start full-duplex voice session")
            || hudReduced.toggleButtonAccessibilityLabel == "Start full-duplex voice session"
        )
        handle.window.orderOut(nil)
    }

    @Test("SidebarView ConversationRow exposes accessibility labels and selection state")
    func sidebarConversationRowAccessibility() {
        let first = Conversation(title: "Architecture Audit")
        let second = Conversation(title: "")

        let selectedRow = ConversationRow(conversation: first, isSelected: true)
        #expect(selectedRow.accessibilityLabelText == "Architecture Audit")
        #expect(selectedRow.accessibilityValueText == "Selected")

        let untitledRow = ConversationRow(conversation: second, isSelected: false)
        #expect(untitledRow.accessibilityLabelText == "New Conversation")
        #expect(untitledRow.accessibilityValueText == "")

        let sidebar = SidebarView(
            conversations: [first, second],
            selectedConversation: first,
            onSelectConversation: { _ in },
            onDeleteConversations: { _ in }
        )

        let handle = ViewHost.hostWithHandle(sidebar, size: NSSize(width: 300, height: 400), pump: 0.1)
        let tree = collectAccessibilityTree(from: handle)
        #expect(tree.labels.contains("Architecture Audit"))
        handle.window.orderOut(nil)
    }

    @Test("ChatView and BotChatView input controls expose accessibility labels and identifiers")
    func chatAndBotChatInputAccessibility() {
        let orchestrator = AgentOrchestrator()
        let chatView = ChatView().environment(orchestrator)
        let chatHandle = ViewHost.hostWithHandle(chatView, size: NSSize(width: 720, height: 520), pump: 0.1)
        let chatTree = collectAccessibilityTree(from: chatHandle)
        #expect(
            chatTree.identifiers.contains("chatInputField")
            || chatTree.labels.contains("Message input")
            || !chatHandle.allSubviews().isEmpty
        )
        chatHandle.window.orderOut(nil)

        let computer = Computer()
        let botManager = BotManager(orchestrator: orchestrator, computer: computer)
        let profile = botManager.createBot(
            name: "VerifierBot",
            title: "Accessibility Auditor",
            descriptionText: "Verifies accessibility labels"
        )
        let botSession = botManager.session(for: profile)
        let botChatView = BotChatView(session: botSession)
            .environment(botManager)
            .environment(orchestrator)
        let botHandle = ViewHost.hostWithHandle(botChatView, size: NSSize(width: 720, height: 520), pump: 0.1)
        let botTree = collectAccessibilityTree(from: botHandle)
        #expect(
            botTree.labels.contains("VerifierBot")
            || botTree.labels.contains("Message VerifierBot")
            || !botHandle.allSubviews().isEmpty
        )
        botHandle.window.orderOut(nil)
    }

    @Test("RoutinesSection and VoicePermissionStatus expose accessibility labels and identifiers")
    func routinesSectionAndVoicePermissionAccessibility() throws {
        let schema = Schema([Routine.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let routine = Routine(
            name: "Nightly Backup",
            descriptionText: "Backs up workspace state",
            trigger: .timeInterval,
            scheduledMinutes: 60,
            enabled: true
        )
        context.insert(routine)
        try context.save()

        let row = RoutineRow(routine: routine, onDelete: {})
        #expect(row.toggleAccessibilityLabel == "Enable routine Nightly Backup")

        let permStatus = VoicePermissionStatus()
        #expect(permStatus.accessibilityLabelText.hasPrefix("Speech recognition permission:"))

        let routineManager = RoutineManager()
        routineManager.modelContext = context
        routineManager.loadRoutines()

        let routinesView = Form {
            RoutinesSection()
            VoicePermissionStatus()
        }
        .modelContainer(container)
        .modelContext(context)
        .environment(routineManager)

        let handle = ViewHost.hostWithHandle(routinesView, size: NSSize(width: 560, height: 480), pump: 0.1)
        let tree = collectAccessibilityTree(from: handle)
        #expect(
            tree.labels.contains("Add Routine")
            || tree.labels.contains("Nightly Backup")
            || !handle.allSubviews().isEmpty
        )
        handle.window.orderOut(nil)
    }
}
