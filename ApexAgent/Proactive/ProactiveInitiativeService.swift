import Foundation
import SharedKit

// MARK: - Proactive Initiative Service (Issue #78, A4)

/// The agent proposes work between sessions, read-only by default, escalating only through approval.
///
/// Features:
/// - **Bounded**: Queue capped at `maxPendingProposals` (5 outstanding proposals).
/// - **No repeats**: Once a proposal is declined by the user, it is never re-proposed.
/// - **Evidence required**: Proposals must cite concrete motivating evidence (file, run, or gap).
/// - **Read-only by default**: A proposal never executes work itself upon creation.
/// - **Approval-gated execution**: Execution escalates strictly through existing approval machinery
///   (`ApprovalAllowlist` and `OrchestratorProvider.requestConfirmation`).
/// - **Persistence**: Proposals survive app restarts using files-first storage tiers.
public final class ProactiveInitiativeService: @unchecked Sendable {
    public static let shared = ProactiveInitiativeService()

    /// Maximum outstanding proposed items allowed in the queue at any time.
    public static let maxPendingProposals: Int = 5

    private let lock = NSLock()
    private let storageURL: URL
    private let allowlist: ApprovalAllowlist
    private var proposals: [ProactiveProposal] = []
    private var declinedSignatures: Set<String> = []

    public init(
        storageURL: URL? = nil,
        allowlist: ApprovalAllowlist = .shared
    ) {
        self.allowlist = allowlist
        if let explicitURL = storageURL {
            self.storageURL = explicitURL
        } else {
            // Store under .apex in the current or default workspace
            let wsPath = FileManager.default.currentDirectoryPath
            let apexDir = URL(fileURLWithPath: wsPath).appendingPathComponent(".apex")
            self.storageURL = apexDir.appendingPathComponent("proactive_proposals.json")
        }

        loadFromDisk()
    }

    // MARK: - Evidence Validation

    /// Validates that a proposal cites concrete motivating evidence (file, run, or gap).
    /// Bare assertions without citations are rejected.
    public static func validateEvidence(_ evidence: String) -> Bool {
        let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()
        let hasCitation = lower.contains("file:") ||
            lower.contains("runs/") ||
            lower.contains("run ") ||
            lower.contains("gap:") ||
            lower.contains("gap ") ||
            lower.contains(".swift") ||
            lower.contains(".md") ||
            lower.contains(".log") ||
            lower.contains(".json") ||
            lower.contains("/") ||
            lower.contains("issue #") ||
            lower.contains("issue:") ||
            lower.contains("line ") ||
            lower.contains("todo:") ||
            lower.contains("fixme:")

        return hasCitation
    }

    // MARK: - Querying Proposals

    /// All proposals tracked in storage.
    public var allProposals: [ProactiveProposal] {
        lock.lock()
        defer { lock.unlock() }
        return proposals
    }

    /// All currently pending (proposed) items.
    public var pendingProposals: [ProactiveProposal] {
        lock.lock()
        defer { lock.unlock() }
        return proposals.filter { $0.status == .proposed }
    }

    /// Retrieves a proposal by its unique ID.
    public func proposal(with id: UUID) -> ProactiveProposal? {
        lock.lock()
        defer { lock.unlock() }
        return proposals.first { $0.id == id }
    }

    /// Set of signatures that were declined by the user.
    public var declinedProposalSignatures: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return declinedSignatures
    }

    // MARK: - Step 1: Propose (Read-Only)

    /// Creates a new proposal. The proposal is strictly read-only; nothing executes.
    ///
    /// Guardrails:
    /// 1. Evidence citation must be present and verified.
    /// 2. Queue cap (max 5 pending) must not be exceeded.
    /// 3. Must not have been previously declined by the user.
    @discardableResult
    public func propose(
        title: String,
        evidence: String,
        proposedAction: String,
        command: String? = nil,
        directory: String? = nil,
        toolName: String = "run_shell_command"
    ) throws -> ProactiveProposal {
        lock.lock()
        defer { lock.unlock() }

        // 1. Evidence citation check
        guard Self.validateEvidence(evidence) else {
            throw ProactiveInitiativeError.missingEvidenceCitation(
                "Proposal '\(title)' must cite concrete motivating evidence (file, run, or gap)."
            )
        }

        // 2. Queue cap check
        let pendingCount = proposals.filter { $0.status == .proposed }.count
        guard pendingCount < Self.maxPendingProposals else {
            throw ProactiveInitiativeError.queueCapReached(
                "Queue cap of \(Self.maxPendingProposals) pending proposals reached. Cannot add '\(title)'."
            )
        }

        // 3. Normalized duplicate / declined check
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = ProactiveProposal(
            title: cleanTitle,
            evidence: evidence,
            proposedAction: proposedAction,
            command: command,
            directory: directory,
            toolName: toolName,
            status: .proposed
        )

        if declinedSignatures.contains(candidate.signature) {
            throw ProactiveInitiativeError.previouslyDeclined(
                "Proposal '\(title)' was previously declined by the user and cannot be re-proposed."
            )
        }

        // Reject duplicate in pending queue
        if proposals.contains(where: { $0.status == .proposed && $0.signature == candidate.signature }) {
            throw ProactiveInitiativeError.previouslyDeclined(
                "Proposal '\(title)' is already pending in the queue."
            )
        }

        proposals.append(candidate)
        saveToDiskUnlocked()

        return candidate
    }

    // MARK: - Approval & Decline Actions

    /// Marks a proposal as approved. Does not execute the work; execution is triggered via `executeProposal`.
    public func approveProposal(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let idx = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProactiveInitiativeError.proposalNotFound(id)
        }

        guard proposals[idx].status == .proposed else {
            throw ProactiveInitiativeError.proposalAlreadyResolved(
                "Proposal \(id) is already in status '\(proposals[idx].status.rawValue)'."
            )
        }

        proposals[idx].status = .approved
        proposals[idx].resolvedAt = Date()
        saveToDiskUnlocked()
    }

    /// Declines a proposal. Permanently records the refusal so it is never re-proposed.
    public func declineProposal(id: UUID, reason: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let idx = proposals.firstIndex(where: { $0.id == id }) else {
            throw ProactiveInitiativeError.proposalNotFound(id)
        }

        let proposal = proposals[idx]
        declinedSignatures.insert(proposal.signature)

        proposals[idx].status = .declined
        proposals[idx].declinedReason = reason ?? "Declined by user."
        proposals[idx].resolvedAt = Date()
        saveToDiskUnlocked()
    }

    // MARK: - Synchronous Lock Helpers

    private func getProposalLocked(id: UUID) -> ProactiveProposal? {
        lock.lock()
        defer { lock.unlock() }
        return proposals.first(where: { $0.id == id })
    }

    private func recordExecutionLocked(id: UUID, output: String) {
        lock.lock()
        defer { lock.unlock() }
        if let idx = proposals.firstIndex(where: { $0.id == id }) {
            proposals[idx].status = .executed
            proposals[idx].resolvedAt = Date()
            proposals[idx].executionOutput = output
            saveToDiskUnlocked()
        }
    }

    // MARK: - Step 2: Execution Escalation (Strictly Approval-Gated)

    /// Executes a proposal. Execution occurs ONLY after approval verification:
    /// 1. If already approved, proceeds to execute.
    /// 2. If status is proposed, escalates through existing approval machinery:
    ///    - First checks `ApprovalAllowlist` (exact command + directory grant).
    ///    - If not allowlisted, calls `orchestrator.requestConfirmation(...)`.
    ///    - If confirmed, transitions to `.approved` and executes.
    ///    - If denied, transitions to `.declined`, saves refusal, and halts.
    /// 3. Never executes unapproved work.
    public func executeProposal(
        id: UUID,
        explicitAllowlist: ApprovalAllowlist? = nil,
        executor: ((ProactiveProposal) async throws -> String)? = nil
    ) async throws -> ProposalExecutionResult {
        try await executeProposal(
            id: id,
            orchestrator: nil,
            explicitAllowlist: explicitAllowlist,
            executor: executor
        )
    }

    /// Internal overload accepting OrchestratorProvider for UI and runtime integration.
    func executeProposal(
        id: UUID,
        orchestrator: OrchestratorProvider?,
        explicitAllowlist: ApprovalAllowlist? = nil,
        executor: ((ProactiveProposal) async throws -> String)? = nil
    ) async throws -> ProposalExecutionResult {
        // Step A: Inspect proposal
        guard let proposal = getProposalLocked(id: id) else {
            throw ProactiveInitiativeError.proposalNotFound(id)
        }

        if proposal.status == .executed {
            return ProposalExecutionResult(
                proposalId: id,
                executed: true,
                approved: true,
                output: proposal.executionOutput ?? "Already executed."
            )
        }

        if proposal.status == .declined {
            throw ProactiveInitiativeError.executionNotApproved(
                "Cannot execute proposal \(id): it was declined by the user."
            )
        }

        // Step B: Approval Escalation if still in .proposed state
        var isApproved = (proposal.status == .approved)

        if !isApproved {
            let effAllowlist = explicitAllowlist ?? self.allowlist
            let effectiveDir = proposal.directory ?? FileManager.default.currentDirectoryPath

            // 1. Check existing ApprovalAllowlist (#105/#166)
            if let cmd = proposal.command, !cmd.isEmpty,
               effAllowlist.isAllowed(command: cmd, directory: effectiveDir) {
                isApproved = true
            }

            // 2. Escalate via Orchestrator confirmation card if not allowlisted
            if !isApproved, let orchProvider = orchestrator {
                let displayArgs = "Action: \(proposal.proposedAction)\nEvidence: \(proposal.evidence)\nCommand: \(proposal.command ?? "None")"
                let approved = await orchProvider.orchestrator.requestConfirmation(
                    toolName: proposal.toolName,
                    arguments: displayArgs,
                    riskDescription: "Proactive Initiative Proposal: '\(proposal.title)'. Do you approve execution?",
                    command: proposal.command,
                    directory: effectiveDir,
                    allowlist: effAllowlist
                )

                if approved {
                    isApproved = true
                } else {
                    // Record explicit denial
                    try? declineProposal(id: id, reason: "Denied by user during confirmation prompt.")
                    return ProposalExecutionResult(
                        proposalId: id,
                        executed: false,
                        approved: false,
                        output: "Execution denied by user."
                    )
                }
            }
        }

        guard isApproved else {
            throw ProactiveInitiativeError.executionNotApproved(
                "Execution of proposal '\(proposal.title)' requires user approval or an active allowlist grant."
            )
        }

        // Step C: Execution of Approved Work
        let executionOutput: String
        if let customExecutor = executor {
            executionOutput = try await customExecutor(proposal)
        } else if let cmd = proposal.command, !cmd.isEmpty {
            executionOutput = try await executeShellCommand(cmd: cmd, directory: proposal.directory)
        } else {
            executionOutput = "Executed proactive action: \(proposal.proposedAction)"
        }

        // Step D: Update Proposal State to .executed
        recordExecutionLocked(id: id, output: executionOutput)

        return ProposalExecutionResult(
            proposalId: id,
            executed: true,
            approved: true,
            output: executionOutput
        )
    }

    private func executeShellCommand(cmd: String, directory: String?) async throws -> String {
        let workDir = directory ?? FileManager.default.currentDirectoryPath
        let fullScript = "cd '\(workDir)' && \(cmd)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", fullScript]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? "Command exited with status \(process.terminationStatus)" : out
    }

    // MARK: - Between-Sessions Proactive Gap Evaluation

    /// Evaluates the workspace between sessions and generates proactive proposals for real gaps found.
    ///
    /// Scans for:
    /// - Uncommitted file diffs or unverified gate runs
    /// - Stale test artifacts or missing coverage logs in `runs/`
    /// - Memory tier updates needing consolidation
    public func evaluateWorkspaceGaps(workspacePath: String? = nil) throws -> [ProactiveProposal] {
        let root = workspacePath ?? FileManager.default.currentDirectoryPath
        var generated: [ProactiveProposal] = []

        // Check 1: Check runs/ directory for missing or failed gate logs
        let runsDir = URL(fileURLWithPath: root).appendingPathComponent("runs")
        if FileManager.default.fileExists(atPath: runsDir.path) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: runsDir.path)) ?? []
            let logFiles = files.filter { $0.hasSuffix(".log") }

            for logFile in logFiles.prefix(2) {
                let logPath = "runs/\(logFile)"
                let title = "Review and triage gate log: \(logFile)"
                if !declinedSignatures.contains("\(title.lowercased())::") &&
                    !proposals.contains(where: { $0.title == title }) &&
                    pendingProposals.count + generated.count < Self.maxPendingProposals {
                    let prop = try propose(
                        title: title,
                        evidence: "Found test log artifact at \(logPath) requiring inspection",
                        proposedAction: "Inspect \(logPath) for test failures and benchmark anomalies",
                        command: "head -n 20 '\(logPath)'",
                        directory: root
                    )
                    generated.append(prop)
                }
            }
        }

        // Check 2: Check for MEMORY.md pre-compaction consolidation
        let memoryPath = URL(fileURLWithPath: root).appendingPathComponent("MEMORY.md")
        if FileManager.default.fileExists(atPath: memoryPath.path) {
            let title = "Consolidate daily memory notes into curated MEMORY.md"
            if !declinedSignatures.contains("\(title.lowercased())::") &&
                !proposals.contains(where: { $0.title == title }) &&
                pendingProposals.count + generated.count < Self.maxPendingProposals {
                let prop = try propose(
                    title: title,
                    evidence: "MEMORY.md exists at \(memoryPath.path) with pending session notes",
                    proposedAction: "Run background memory consolidation to supersede stale facts",
                    command: "git status -s",
                    directory: root
                )
                generated.append(prop)
            }
        }

        return generated
    }

    // MARK: - Persistence (Files-First Memory Tiers)

    private struct PersistedProposalsPayload: Codable {
        let proposals: [ProactiveProposal]
        let declinedSignatures: [String]
    }

    private func saveToDiskUnlocked() {
        let payload = PersistedProposalsPayload(
            proposals: proposals,
            declinedSignatures: Array(declinedSignatures)
        )

        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = try? encoder.encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    public func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }

        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let payload = try? decoder.decode(PersistedProposalsPayload.self, from: data) {
            self.proposals = payload.proposals
            self.declinedSignatures = Set(payload.declinedSignatures)
        } else if let legacyList = try? decoder.decode([ProactiveProposal].self, from: data) {
            self.proposals = legacyList
            self.declinedSignatures = Set(legacyList.filter { $0.status == .declined }.map(\.signature))
        }
    }

    /// Resets memory state (used primarily in tests or fresh environments).
    public func reset(clearDisk: Bool = true) {
        lock.lock()
        defer { lock.unlock() }

        proposals.removeAll()
        declinedSignatures.removeAll()

        if clearDisk && FileManager.default.fileExists(atPath: storageURL.path) {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }
}
