import Testing
import Foundation
@testable import ApexAgentCore

@Suite("TartCLIClient pure functions")
struct TartCLIClientPureTests {
    @Test func cloneArguments() {
        #expect(TartCLIClient.cloneArguments(source: "apex-base", name: "apex-probe") == ["clone", "apex-base", "apex-probe"])
    }

    @Test func setArguments() {
        #expect(TartCLIClient.setArguments(name: "apex-shared", cpu: 8, memoryMB: 10240) == ["set", "apex-shared", "--cpu", "8", "--memory", "10240"])
        #expect(TartCLIClient.setArguments(name: "x") == ["set", "x"])
    }

    @Test func runArguments() {
        #expect(TartCLIClient.runArguments(name: "apex-shared", softnet: true) == ["run", "--net-softnet", "apex-shared"])
        #expect(TartCLIClient.runArguments(name: "apex-shared", softnet: false) == ["run", "apex-shared"])
    }

    @Test func execArguments() {
        #expect(TartCLIClient.execArguments(name: "apex-shared", arguments: ["echo", "ok"]) == ["exec", "apex-shared", "echo", "ok"])
    }

    @Test func ipArguments() {
        #expect(TartCLIClient.ipArguments(name: "apex-shared") == ["ip", "apex-shared"])
        #expect(TartCLIClient.ipArguments(name: "apex-shared", wait: 60) == ["ip", "apex-shared", "--wait", "60"])
    }

    @Test func stopDeleteListArguments() {
        #expect(TartCLIClient.stopArguments(name: "apex-shared") == ["stop", "apex-shared"])
        #expect(TartCLIClient.deleteArguments(name: "apex-shared") == ["delete", "apex-shared"])
        #expect(TartCLIClient.listArguments() == ["list", "--format", "json"])
    }

    @Test func parseVMList() throws {
        let json = """
        [{"Name":"apex-base","Source":"local","State":"stopped","Running":false,"Disk":113,"Size":113}]
        """
        let vms = try TartCLIClient.parseVMList(Data(json.utf8))
        #expect(vms.count == 1)
        #expect(vms.first?.name == "apex-base")
        #expect(vms.first?.running == false)
    }

    @Test func parseIP() {
        #expect(TartCLIClient.parseIP("  192.168.2.20\n") == "192.168.2.20")
        #expect(TartCLIClient.parseIP("   ") == nil)
    }

    @Test func vmNaming() {
        #expect(VMWorkspaceManager.vmName(for: "alpha") == "apex-space-alpha")
        #expect(VMWorkspaceManager.vmNamePrefix == "apex-space-")
        #expect(VMWorkspaceManager.sourceVMName == "apex-base")
        #expect(VMWorkspaceManager.maxConcurrentRunning == 2)
    }
}
