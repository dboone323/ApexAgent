import Testing
import Foundation
@testable import ApexAgentCore

// MARK: - Proactive Initiative Tests (Issue #78, A4)

@Suite("ProactiveInitiativeTests")
struct ProactiveInitiativeTests {

    private func makeTemporaryStorage() -> (dir: URL, file: URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apex_test_proactive_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storageFile = tempDir.appendingPathComponent("proposals.json")
        return (tempDir, storageFile)
    }

    // MARK: - 1. Proposal Created Read-Only (Nothing Executes)

    @Test func testProposalCreatedReadOnlyNothingExecutes() throws {
        let (tempDir, storageFile) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let evidenceFile = tempDir.appendingPathComponent("test-evidence.log")
        try "Line 10: Potential resource leak in session dispatcher\n".write(to: evidenceFile, atomically: true, encoding: .utf8)

        let service = ProactiveInitiativeService(storageURL: storageFile)

        // Bare assertion without concrete citation is rejected
        #expect(throws: ProactiveInitiativeError.missingEvidenceCitation("Proposal 'Bare assertion' must cite concrete motivating evidence (file, run, or gap).")) {
            try service.propose(
                title: "Bare assertion",
                evidence: "No file or log cited here",
                proposedAction: "Do nothing"
            )
        }

        let proposal = try service.propose(
            title: "Triage session dispatcher leak",
            evidence: "Evidence cited in file://\(evidenceFile.path) at line 10",
            proposedAction: "Inspect session dispatcher resource cleanup",
            command: "echo 'inspecting'",
            directory: tempDir.path
        )

        // Read-only state verification: nothing executed
        #expect(proposal.status == .proposed)
        #expect(proposal.resolvedAt == nil)
        #expect(proposal.declinedReason == nil)
        #expect(proposal.executionOutput == nil)

        // Appears in pending queue
        let pending = service.pendingProposals
        #expect(pending.count == 1)
        #expect(pending.first?.id == proposal.id)

        // Verified persisted on disk
        #expect(FileManager.default.fileExists(atPath: storageFile.path))
    }

    // MARK: - 2. Approval Required Before Execution

    @Test func testApprovalRequiredBeforeExecution() async throws {
        let (tempDir, storageFile) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let suiteName = "test.proactive.allowlist.\(UUID().uuidString)"
        let customDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        let freshAllowlist = ApprovalAllowlist(userDefaults: customDefaults)
        freshAllowlist.removeAll()

        let service = ProactiveInitiativeService(storageURL: storageFile, allowlist: freshAllowlist)

        let proposal = try service.propose(
            title: "Execute security lint scan",
            evidence: "Found gap citation in runs/audit/gap.log",
            proposedAction: "Run static analyzer",
            command: "echo 'PROACTIVE_APPROVED_OK'",
            directory: tempDir.path
        )

        // Attempting execution without approval or orchestrator must fail closed
        var didCatchUnapprovedError = false
        do {
            _ = try await service.executeProposal(
                id: proposal.id,
                orchestrator: nil,
                explicitAllowlist: freshAllowlist
            )
        } catch ProactiveInitiativeError.executionNotApproved {
            didCatchUnapprovedError = true
        }

        #expect(didCatchUnapprovedError)

        // State remains strictly unexecuted and proposed
        let current = service.proposal(with: proposal.id)
        #expect(current?.status == .proposed)
        #expect(current?.resolvedAt == nil)
        #expect(current?.executionOutput == nil)

        // Now grant approval through allowlist
        freshAllowlist.allow(command: "echo 'PROACTIVE_APPROVED_OK'", directory: tempDir.path)

        // Execution now succeeds through the approval system
        let result = try await service.executeProposal(
            id: proposal.id,
            explicitAllowlist: freshAllowlist
        )
        #expect(result.executed)
        #expect(result.approved)
        #expect(result.output.contains("PROACTIVE_APPROVED_OK"))

        let executedProposal = service.proposal(with: proposal.id)
        #expect(executedProposal?.status == .executed)
        #expect(executedProposal?.resolvedAt != nil)
    }

    // MARK: - 3. Declined Proposal Never Re-Proposed

    @Test func testDeclinedProposalNeverReproposed() throws {
        let (tempDir, storageFile) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = ProactiveInitiativeService(storageURL: storageFile)

        let proposal = try service.propose(
            title: "Purge intermediate build cache",
            evidence: "Large build cache found in runs/issue78/build.log",
            proposedAction: "Remove derived data artifacts",
            command: "echo 'purge'",
            directory: tempDir.path
        )

        // Decline the proposal
        try service.declineProposal(id: proposal.id, reason: "Declined: cache preservation needed for debugging.")

        let declined = service.proposal(with: proposal.id)
        #expect(declined?.status == .declined)
        #expect(declined?.declinedReason == "Declined: cache preservation needed for debugging.")
        #expect(service.pendingProposals.isEmpty)
        #expect(service.declinedProposalSignatures.contains(proposal.signature))

        // Attempting to re-propose the same proposal must be blocked
        var reproposalBlocked = false
        do {
            _ = try service.propose(
                title: "Purge intermediate build cache",
                evidence: "Large build cache found in runs/issue78/build.log",
                proposedAction: "Remove derived data artifacts",
                command: "echo 'purge'",
                directory: tempDir.path
            )
        } catch ProactiveInitiativeError.previouslyDeclined {
            reproposalBlocked = true
        }

        #expect(reproposalBlocked)
    }

    // MARK: - 4. Queue Cap Enforced

    @Test func testQueueCapEnforced() throws {
        let (tempDir, storageFile) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let service = ProactiveInitiativeService(storageURL: storageFile)

        // Add up to cap (5 pending proposals)
        for i in 1...ProactiveInitiativeService.maxPendingProposals {
            _ = try service.propose(
                title: "Task proposal \(i)",
                evidence: "Citation in file://\(tempDir.path)/item_\(i).swift",
                proposedAction: "Action for item \(i)",
                command: "echo 'item \(i)'",
                directory: tempDir.path
            )
        }

        #expect(service.pendingProposals.count == ProactiveInitiativeService.maxPendingProposals)

        // Attempt to exceed cap with 6th proposal
        var capExceededBlocked = false
        do {
            _ = try service.propose(
                title: "Task proposal 6",
                evidence: "Citation in file://\(tempDir.path)/item_6.swift",
                proposedAction: "Action for item 6",
                command: "echo 'item 6'",
                directory: tempDir.path
            )
        } catch ProactiveInitiativeError.queueCapReached {
            capExceededBlocked = true
        }

        #expect(capExceededBlocked)
        #expect(service.pendingProposals.count == ProactiveInitiativeService.maxPendingProposals)

        // Resolving one proposal opens up space under the cap
        if let firstPending = service.pendingProposals.first {
            try service.declineProposal(id: firstPending.id, reason: "Freeing queue space")
            #expect(service.pendingProposals.count == ProactiveInitiativeService.maxPendingProposals - 1)

            // Now adding proposal 6 succeeds
            let p6 = try service.propose(
                title: "Task proposal 6",
                evidence: "Citation in file://\(tempDir.path)/item_6.swift",
                proposedAction: "Action for item 6",
                command: "echo 'item 6'",
                directory: tempDir.path
            )
            #expect(p6.status == .proposed)
            #expect(service.pendingProposals.count == ProactiveInitiativeService.maxPendingProposals)
        }
    }

    // MARK: - 5. Proposals Persist Across Restart

    @Test func testProposalsPersistAcrossRestart() async throws {
        let (tempDir, storageFile) = makeTemporaryStorage()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var executedId: UUID?
        var declinedId: UUID?
        var pendingId: UUID?

        do {
            let service1 = ProactiveInitiativeService(storageURL: storageFile)

            let p1 = try service1.propose(
                title: "Persistent task to execute",
                evidence: "Citation in runs/issue78/check.log",
                proposedAction: "Run echo probe",
                command: "echo 'PERSISTENCE_SUCCESS'",
                directory: tempDir.path
            )
            executedId = p1.id
            try service1.approveProposal(id: p1.id)
            _ = try await service1.executeProposal(id: p1.id)

            let p2 = try service1.propose(
                title: "Persistent task to decline",
                evidence: "Citation in runs/issue78/gap2.log",
                proposedAction: "Decline action",
                command: "echo 'declined'",
                directory: tempDir.path
            )
            declinedId = p2.id
            try service1.declineProposal(id: p2.id, reason: "Not needed")

            let p3 = try service1.propose(
                title: "Persistent task pending",
                evidence: "Citation in file://\(tempDir.path)/file.swift",
                proposedAction: "Pending action",
                command: "echo 'pending'",
                directory: tempDir.path
            )
            pendingId = p3.id
        }

        // Fresh service instance simulating application restart
        let service2 = ProactiveInitiativeService(storageURL: storageFile)

        #expect(service2.allProposals.count == 3)
        #expect(service2.pendingProposals.count == 1)
        #expect(service2.pendingProposals.first?.id == pendingId)

        let reloadedP1 = service2.proposal(with: executedId!)
        #expect(reloadedP1?.status == .executed)
        #expect(reloadedP1?.executionOutput?.contains("PERSISTENCE_SUCCESS") == true)

        let reloadedP2 = service2.proposal(with: declinedId!)
        #expect(reloadedP2?.status == .declined)
        #expect(reloadedP2?.declinedReason == "Not needed")

        // Declined signatures persist: re-proposing p2 must still be blocked
        var reproposalBlocked = false
        do {
            _ = try service2.propose(
                title: "Persistent task to decline",
                evidence: "Citation in runs/issue78/gap2.log",
                proposedAction: "Decline action",
                command: "echo 'declined'",
                directory: tempDir.path
            )
        } catch ProactiveInitiativeError.previouslyDeclined {
            reproposalBlocked = true
        }
        #expect(reproposalBlocked)
    }
}
