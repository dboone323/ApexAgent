import Foundation

// MARK: - ApprovalPolicy: auto-approve verdicts for the confirmation gate
//
// Two ways in — the bot is in auto mode, or the user pressed "Always allow"
// for one specific tool — and one way out: anything that reads as destructive
// stops and asks a human anyway.
//
// The guard is deliberately tiny and literal. It is NOT a security boundary
// (an agent set on damage has a thousand spellings for `rm`); it is a "you
// probably didn't mean to hand THIS one over unattended" backstop for the
// obvious catastrophes. Real containment is ApexAgent's sandbox + the bot's
// own computer, not a regex.

enum ApprovalRule {
    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? NSRegularExpression()
    }

    static let destructive: [NSRegularExpression] = [
        makeRegex(#"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]"#, options: [.caseInsensitive]),      // rm -rf, rm -fr
        makeRegex(#"\bmkfs\b|\bdiskutil\s+erase|\bdd\s+[^|]*\bof=/dev/"#, options: [.caseInsensitive]),
        makeRegex(#"\bshutdown\b|\breboot\b|\bhalt\b"#, options: [.caseInsensitive]),
        makeRegex(#":\(\)\s*\{.*\}\s*;?\s*:"#),                                          // fork bomb
        makeRegex(#"\bgit\s+push\s+[^|]*--force(-with-lease)?\b|\bgit\s+reset\s+--hard\b"#, options: [.caseInsensitive]),
        makeRegex(#"\bDROP\s+(TABLE|DATABASE)\b|\bTRUNCATE\s+TABLE\b"#, options: [.caseInsensitive]),
        makeRegex(#"\bsudo\s+rm\b|\bchmod\s+-R\s+777\s+/"#, options: [.caseInsensitive])
    ]

    /// Not destructive, but exactly what you don't hand over unattended:
    /// a bot reading your keys is quiet, permanent, and unrecoverable.
    static let sensitive: [NSRegularExpression] = [
        makeRegex(#"(^|[\s/"'])\.env(\.|$|["'\s])"#, options: [.caseInsensitive]),
        makeRegex(#"\.ssh\/|id_rsa|id_ed25519|authorized_keys"#, options: [.caseInsensitive]),
        makeRegex(#"\.aws\/credentials|\.netrc|\.npmrc|\.pypirc|\.docker\/config\.json"#, options: [.caseInsensitive]),
        makeRegex(#"security\s+find-(generic|internet)-password|\bkeychain\b"#, options: [.caseInsensitive]),
        makeRegex(#"\bcredentials?\.json\b|\bserviceaccount\b"#, options: [.caseInsensitive])
    ]

    static let hostDiskDestructive: [NSRegularExpression] = [
        makeRegex(#"\bdiskutil\s+erase|\bdd\s+[^|]*\bof=/dev/(r?disk|nvme)"#, options: [.caseInsensitive]),
        makeRegex(#"\bmkfs\b"#, options: [.caseInsensitive]),
        makeRegex(#"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf]"#, options: [.caseInsensitive])
    ]

    static let hostDiskDestructiveContainer: [NSRegularExpression] = [
        makeRegex(#"\bdiskutil\s+erase|\bdd\s+[^|]*\bof=/dev/(r?disk|nvme)"#, options: [.caseInsensitive]),
        makeRegex(#"\bmkfs\b"#, options: [.caseInsensitive])
    ]

    static let networkPatterns: [NSRegularExpression] = [
        makeRegex(#"(?:^|[|;&\s])(curl|wget|nc|netcat|ssh|scp|sftp|ping|telnet)\b"#, options: [.caseInsensitive]),
        makeRegex(#"https?://"#, options: [.caseInsensitive])
    ]
}

/// Which rule produced the verdict — the decision log's whole value is "which
/// rule", so the source is carried on the verdict rather than re-derived.
enum ApprovalVerdictSource: String, Sendable {
    case alwaysAllow = "always-allow"
    case autoMode = "auto-mode"
    case containerSandbox = "container-sandbox"
    case destructiveGuard = "destructive-guard"
    case sensitiveGuard = "sensitive-guard"
    case unattendedBlock = "unattended-block"
    case localComputerBlock = "local-computer-block"
    case governanceBlock = "governance-block"
    case noGrant = "no-grant"
    /// The human answered a card themselves (decision-log attribution only —
    /// never produced by `ApprovalPolicy.verdict`).
    case user = "user"
    case autoReview = "auto-review"
    case allowlist = "allowlist"
}

/// The verdict for one permission request. `approve` is non-nil exactly when
/// the request may be answered without the human.
struct ApprovalVerdict: Equatable, Sendable {
    let approve: String?
    let source: ApprovalVerdictSource
    let rule: String?
}

/// Command-running tools whose "always allow" grant is narrowed to a specific
/// program, so remembering `run_shell_command` grants `run_shell_command:git`,
/// never a permanent unattended shell. Includes both ApexAgent's native shell
/// tool name and generic aliases.
private let commandTools: Set<String> = [
    "run_shell_command", "bash", "shell", "execute", "run_command",
    "computer_exec", "terminal",
]

// MARK: - Policy logic

enum ApprovalPolicy {

    /// First matching pattern's source string, or nil — so a verdict can NAME
    /// the rule that made it.
    private static func matchFirst(_ rules: [NSRegularExpression], in text: String) -> String? {
        for rule in rules {
            let range = rule.rangeOfFirstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            if range.location != NSNotFound { return rule.pattern }
        }
        return nil
    }

    static func looksDestructive(_ text: String) -> Bool {
        matchFirst(ApprovalRule.destructive, in: text) != nil
    }

    static func looksSensitive(_ text: String) -> Bool {
        matchFirst(ApprovalRule.sensitive, in: text) != nil
    }

    /// A stable name for the destructive guard (decision-log attribution).
    static var destructiveGuardRuleName: String {
        ApprovalRule.destructive.first?.pattern ?? "destructive-guard"
    }

    /// The key an "Always allow" grant is remembered under. A bare tool name
    /// is far too coarse for a command runner, so command tools are keyed by
    /// their program — `run_shell_command:git`, `run_shell_command:npm` — so
    /// the grant is as narrow as the thing you actually looked at.
    static func approvalKey(tool: String, summary: String) -> String {
        var bare = tool
        if let mcpRange = bare.range(of: #"^mcp__[^_]+__"#, options: .regularExpression) {
            bare.removeSubrange(mcpRange)
        }
        bare = bare.lowercased()
        guard commandTools.contains(bare) else { return tool }

        // First bare word of the command, skipping env assignments and sudo.
        let words = summary.split(whereSeparator: { $0.isWhitespace })
        var i = 0
        while i < words.count {
            let word = String(words[i])
            let isEnvAssign = word.range(of: #"^[A-Z_][A-Z0-9_]*="#, options: .regularExpression) != nil
            if isEnvAssign || word == "sudo" { i += 1 } else { break }
        }
        let program = (i < words.count ? String(words[i]) : "")
            .split(separator: "/").last?
            .replacingOccurrences(of: #"[^\w.-]"#, with: "", options: .regularExpression) ?? ""
        return program.isEmpty ? tool : "\(tool):\(program)"
    }

    /// Decide whether a permission request may be auto-answered, using a
    /// SecurityGovernanceProfile preset (hostStrict, containerStandard, etc.).
    /// - Parameter governanceProfile: the profile whose scope, sandbox flag, and
    ///   guard booleans drive the verdict. Mapped to the underlying alwaysAllow /
    ///   autoApprove / unattended / localScope / isContainerSandboxed switches.
    static func verdict(
        tool: String,
        summary: String,
        governanceProfile: SecurityGovernanceProfile
    ) -> ApprovalVerdict {
        // 1. Sensitive file guards check (highest priority: reading keys/secrets must return sensitiveGuard)
        if governanceProfile.blockSensitiveFileAccess && looksSensitive(summary) {
            let matched = matchFirst(ApprovalRule.sensitive, in: summary)
            return ApprovalVerdict(approve: nil, source: .sensitiveGuard, rule: matched)
        }

        // 2. Destructive guards check
        if governanceProfile.blockDestructiveHostCommands && looksDestructive(summary) {
            let hostDiskDestructive = matchFirst(ApprovalRule.hostDiskDestructive, in: summary)
            return ApprovalVerdict(approve: nil, source: .destructiveGuard, rule: hostDiskDestructive ?? destructiveGuardRuleName)
        }

        // 3. Host Strict or profiles disabling network: block network attempts
        if !governanceProfile.allowNetwork {
            if let matched = matchFirst(ApprovalRule.networkPatterns, in: summary) {
                return ApprovalVerdict(approve: nil, source: .governanceBlock, rule: matched)
            }
        }

        // 4. Container sandbox auto-approval
        if governanceProfile.scope == .container && governanceProfile.autoApprovePackageInstall {
            return ApprovalVerdict(approve: "auto-approved in Apple Container sandbox", source: .containerSandbox, rule: nil)
        }

        // 5. Fallback for host scope
        let autoApprove: Bool = governanceProfile.scope == .container
            && governanceProfile.autoApprovePackageInstall
        let isContainerSandboxed: Bool = governanceProfile.scope == .container
        return verdict(
            tool: tool,
            summary: summary,
            autoApprove: autoApprove,
            isContainerSandboxed: isContainerSandboxed
        )
    }

    /// Decide whether a permission request may be auto-answered.
    ///
    /// - Parameters:
    ///   - alwaysAllow: user-remembered grant keys ("Always allow").
    ///   - autoApprove: the bot is in auto mode (user present).
    ///   - unattended: the turn was started by an outside event (webhook/schedule)
    ///     with nobody at the keyboard — auto mode does not inherit it.
    ///   - localScope: the request controls the user's active desktop.
    ///   - isContainerSandboxed: the request executes inside an isolated Apple Container micro-VM.
    static func verdict(
        tool: String,
        summary: String,
        alwaysAllow: [String] = [],
        autoApprove: Bool = false,
        unattended: Bool = false,
        localScope: Bool = false,
        isContainerSandboxed: Bool = false
    ) -> ApprovalVerdict {
        // Fast-path: When running inside an isolated native Apple Container micro-VM:
        // 1. Blast radius is strictly constrained to the ephemeral guest OCI rootfs.
        // 2. Package manager installation (apt/apk), sudo, compilation, and guest filesystem tasks are safe.
        // 3. Only catastrophic host device destruction commands need guarding.
        if isContainerSandboxed {
            let hostDiskDestructive = matchFirst(ApprovalRule.hostDiskDestructiveContainer, in: summary)
            if let hostDiskDestructive {
                return ApprovalVerdict(approve: nil, source: .destructiveGuard, rule: hostDiskDestructive)
            }
            return ApprovalVerdict(approve: "auto-approved in Apple Container sandbox", source: .containerSandbox, rule: nil)
        }

        // Guards outrank grants: an always-allow can never widen into them.
        let destructive = matchFirst(ApprovalRule.destructive, in: summary)
            ?? matchFirst(ApprovalRule.destructive, in: tool)
        let sensitive = destructive == nil ? matchFirst(ApprovalRule.sensitive, in: summary) : nil

        let key = approvalKey(tool: tool, summary: summary)
        let grant: ApprovalVerdict?
        if destructive != nil || sensitive != nil {
            grant = nil
        } else if alwaysAllow.contains(key) {
            grant = ApprovalVerdict(approve: "auto-approved \(key) (always allowed)", source: .alwaysAllow, rule: key)
        } else if autoApprove {
            grant = ApprovalVerdict(approve: "auto-approved \(tool)", source: .autoMode, rule: nil)
        } else {
            grant = nil
        }

        if unattended {
            if let rule = grant?.rule { return ApprovalVerdict(approve: nil, source: .unattendedBlock, rule: rule) }
            if let destructive { return ApprovalVerdict(approve: nil, source: .destructiveGuard, rule: destructive) }
            if let sensitive { return ApprovalVerdict(approve: nil, source: .sensitiveGuard, rule: sensitive) }
            return ApprovalVerdict(approve: nil, source: .noGrant, rule: nil)
        }
        if localScope && !autoApprove {
            if let rule = grant?.rule { return ApprovalVerdict(approve: nil, source: .localComputerBlock, rule: rule) }
            if let destructive { return ApprovalVerdict(approve: nil, source: .destructiveGuard, rule: destructive) }
            if let sensitive { return ApprovalVerdict(approve: nil, source: .sensitiveGuard, rule: sensitive) }
            return ApprovalVerdict(approve: nil, source: .noGrant, rule: nil)
        }
        if let destructive { return ApprovalVerdict(approve: nil, source: .destructiveGuard, rule: destructive) }
        if let sensitive { return ApprovalVerdict(approve: nil, source: .sensitiveGuard, rule: sensitive) }
        if let grant { return grant }
        return ApprovalVerdict(approve: nil, source: .noGrant, rule: nil)
    }


    /// Why this request may be answered without the human, or nil to ask.
    static func autoDecision(
        tool: String,
        summary: String,
        alwaysAllow: [String] = [],
        autoApprove: Bool = false,
        unattended: Bool = false,
        localScope: Bool = false,
        isContainerSandboxed: Bool = false
    ) -> String? {
        verdict(
            tool: tool, summary: summary, alwaysAllow: alwaysAllow,
            autoApprove: autoApprove, unattended: unattended, localScope: localScope,
            isContainerSandboxed: isContainerSandboxed
        ).approve
    }
}
