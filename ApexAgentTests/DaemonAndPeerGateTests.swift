import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - WS3: LaunchAgent plist generation + install lifecycle

@Suite("LaunchAgentTests")
struct LaunchAgentTests {

    private func tempAgentsDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("launchagents-\(UUID().uuidString)", isDirectory: true)
        LaunchAgentController.agentsDirectory = dir
        return dir
    }

    @Test func plistContainsDaemonContract() throws {
        let xml = LaunchAgentPlist.xml(for: LaunchAgentConfig(
            label: "com.apexagent.daemon",
            programPath: "/Applications/ApexAgent.app/Contents/MacOS/ApexAgent",
            arguments: ["--daemon"],
            runAtLoad: true,
            keepAlive: true))
        #expect(xml.contains("<key>Label</key>"))
        #expect(xml.contains("<string>com.apexagent.daemon</string>"))
        #expect(xml.contains("<string>--daemon</string>"))
        #expect(xml.contains("<true/>"))  // RunAtLoad + KeepAlive
        #expect(xml.contains("ProcessType"))
        #expect(xml.contains("Background"))
        // Logs land in ~/Library/Logs so crashes are diagnosable.
        #expect(xml.contains("Library/Logs/com.apexagent.daemon.out.log"))
    }

    @Test func plistEscapesXMLEntitiesInPaths() {
        let xml = LaunchAgentPlist.xml(for: LaunchAgentConfig(
            label: "test.label", programPath: "/opt/weird&<path>/run", arguments: []))
        #expect(!xml.contains("/opt/weird&<path>"))
        #expect(xml.contains("&amp;"))
    }

    @Test func installUninstallLifecycleInInjectableDirectory() throws {
        let dir = tempAgentsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let controller = LaunchAgentController()
        let expectedURL = dir.appendingPathComponent("com.apexagent.daemon.plist")

        #expect(controller.isInstalled == false)
        let written = try controller.install(programPath: "/usr/local/bin/apexagent", arguments: ["--daemon"])
        #expect(written == expectedURL)
        #expect(controller.isInstalled == true)

        // The file on disk must be a real, loadable plist.
        let data = try Data(contentsOf: written)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        let dict = try #require(plist as? [String: Any])
        #expect(dict["Label"] as? String == "com.apexagent.daemon")
        let programArgs = try #require(dict["ProgramArguments"] as? [String])
        #expect(programArgs.first == "/usr/local/bin/apexagent")
        #expect(programArgs.last == "--daemon")

        try controller.uninstall()
        #expect(controller.isInstalled == false)
    }
}

// MARK: - O9 wiring: peer-approval gate for bot-initiated messages

@MainActor
@Suite("PeerDeliveryGateTests")
struct PeerDeliveryGateTests {

    private func makeManagerWithPair() -> (BotManager, BotProfile, BotProfile) {
        let manager = BotManager(orchestrator: AgentOrchestrator(), computer: Computer())
        let chief = manager.createBot(name: "Chief", title: "", descriptionText: "")
        let writer = manager.createBot(name: "Writer", title: "", descriptionText: "")
        _ = manager.session(for: chief)   // ensure sessions exist
        _ = manager.session(for: writer)
        return (manager, chief, writer)
    }

    @Test func unapprovedPeerMessageIsBlockedAndFlagsAttention() {
        let (manager, chief, writer) = makeManagerWithPair()

        guard case .blockedPendingCard(let requestId) =
            manager.peerDeliveryDecision(from: chief, to: writer, message: "draft the post") else {
            Issue.record("expected a pending card without a grant"); return
        }

        let senderSession = manager.session(for: chief)
        #expect(senderSession.needsAttention == true)
        #expect(manager.botsNeedingAttention.map(\.id).contains(chief.id))

        // Deny clears the card and the attention flag; nothing was delivered.
        let allowed = manager.resolvePeerRequest(requestId: requestId, allow: false)
        #expect(allowed == false)
        #expect(senderSession.needsAttention == false)
        #expect(manager.botsNeedingAttention.isEmpty)
        #expect(!manager.peerApprovals.hasGrant(action: .askBot, targetBotId: writer.id.uuidString))
    }

    @Test func allowWithRememberGrantsSilentDeliveryNextTime() {
        let (manager, chief, writer) = makeManagerWithPair()

        guard case .blockedPendingCard(let id) =
            manager.peerDeliveryDecision(from: chief, to: writer, message: "hi") else {
            Issue.record("expected pending card"); return
        }
        let allowed = manager.resolvePeerRequest(requestId: id, allow: true, remember: true)
        #expect(allowed == true)

        let second = manager.peerDeliveryDecision(from: chief, to: writer, message: "again")
        #expect(second == .deliver)

        // A different target still requires its own approval.
        let stranger = manager.createBot(name: "Stranger", title: "", descriptionText: "")
        _ = manager.session(for: stranger)
        let third = manager.peerDeliveryDecision(from: chief, to: stranger, message: "hello?")
        if case .deliver = third { Issue.record("different target must not inherit the grant") }
    }
}