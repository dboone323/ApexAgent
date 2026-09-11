import Testing
import Foundation
@testable import ApexAgentCore

@Suite("SecurityGovernanceTests")
struct SecurityGovernanceTests {

    private func checkPathAllowed(_ profile: SecurityGovernanceProfile, _ path: String) -> Bool {
        do {
            try profile.validateFilesystemAccess(path: path)
            return true
        } catch {
            return false
        }
    }

    @Test func testHostStrictProfilePathRestrictions() {
        let profile = SecurityGovernanceProfile.hostStrict

        #expect(!checkPathAllowed(profile, "/System/Library"))
        #expect(!checkPathAllowed(profile, "/Library"))
        #expect(!checkPathAllowed(profile, "/etc/passwd"))
        #expect(!checkPathAllowed(profile, "/var/log"))
        #expect(!checkPathAllowed(profile, "/usr/bin"))
        #expect(!checkPathAllowed(profile, "/private/etc"))
        #expect(!checkPathAllowed(profile, NSHomeDirectory() + "/.ssh/id_rsa"))
        #expect(!checkPathAllowed(profile, NSHomeDirectory() + "/.aws/credentials"))
    }

    @Test func testPathTraversalPrevention() {
        let profile = SecurityGovernanceProfile.hostStrict
        let traversalPath = NSHomeDirectory() + "/Developer/../../etc/passwd"

        #expect(!checkPathAllowed(profile, traversalPath), "Path traversal via ../ should be blocked")
    }

    @Test func testCommandEvaluationPolicy() {
        let profile = SecurityGovernanceProfile.hostStrict

        let destructiveAllowed = profile.validateCommand(command: "rm -rf /")
        #expect(!destructiveAllowed)

        let safeAllowed = profile.validateCommand(command: "swift build")
        #expect(safeAllowed)
    }

    @Test func testExecutionScopeAndGovernanceProfileKinds() {
        #expect(ExecutionScope.allCases.count == 2)
        #expect(GovernanceProfileKind.allCases.count == 4)

        let containerStd = SecurityGovernanceProfile.containerStandard
        #expect(containerStd.scope == .container)
        #expect(containerStd.autoApprovePackageInstall == true)

        let hostStrict = SecurityGovernanceProfile.hostStrict
        #expect(hostStrict.scope == .host)
        #expect(hostStrict.autoApprovePackageInstall == false)
    }
}
