# Codex Prompt — ApexAgent Deep-Dive Audit (2026-10-22)

**For Daniel — how to use this:**

- Paste the whole block below into Codex, started in `/Users/danielstevens/Developer/ApexAgent`. It's read-only: the only file Codex may create is its report, `CODEX_AUDIT_2026-10-22.md`, in the repo root.
- It's phased so your tokens go to the highest-value work first: **Phase 1** (dynamic ground truth: git, build, tests, UI plan in your real GUI session, crash logs) and **Phase 2** (deep dives on the known-open clusters) matter most. If tokens run short, Phases 3–5 can be pasted again later as a follow-up — each phase stands alone.
- Codex will ask approval for terminal commands. Builds, tests, greps, and reads are what you're approving; it shouldn't need a single write approval except the report file.
- When it's done, paste its chat summary (or the report) back to Monarch. Monarch's static audit is running in parallel — where the two agree, that's high confidence; where they differ is where the interesting problems will be.

---

```
# ApexAgent deep-dive audit — 2026-10-22

You are auditing ApexAgent, a macOS Swift/SwiftUI multi-agent app, on the machine where it lives. Repo root: /Users/danielstevens/Developer/ApexAgent (Xcode project ApexAgent.xcodeproj, scheme ApexAgent). A separate static audit is being done from file reads alone; YOUR advantage is the terminal — you can build, run tests, grep the whole tree, and inspect git and system state. Dive deep. Verify by running, not by reading alone.

RULES
- Read-only. Do not edit, fix, format, commit, or push anything. The ONLY file you may create is your report: /Users/danielstevens/Developer/ApexAgent/CODEX_AUDIT_2026-10-22.md
- Every finding needs evidence: file:line, a grep result, or verbatim command output. Tag each claim [RAN] (verified by executing) or [READ] (verified by reading code).
- If a check can't run (timeout, missing tool, approval denied), record it as NOT RUN with the reason and move on. Never guess.
- Be token-efficient: grep and targeted reads over full-file dumps. In the report, excerpt decisive lines and give counts instead of pasting huge outputs.

PHASE 1 — Dynamic ground truth [all RAN]
1. Git: `git status`, `git log --oneline -15`, `git branch -vv`, `git rev-parse HEAD`. Is PR #29's branch fix/oct20-test-fixes merged into the current branch? (Use `git branch --contains 2f5aa8c7`; `gh pr view 29 --json state,mergedAt` if gh is available.) Note whether these files are committed or untracked: apexagent-sandbox-design.md, antigravity-apexagent-sandbox-prompt.md, antigravity-vm-continuation-prompt.md, codex-prompt-apexagent-deep-audit-2026-10-22.md.
2. Build: `xcodebuild build -project ApexAgent.xcodeproj -scheme ApexAgent -destination "platform=macOS"` — result, error count, and the FULL warning list (deduplicated, with occurrence counts). Known reference warnings: AppIntents metadata notices on 4 packages; redundant Sendable conformance at SpacePageProposal.swift:30.
3. Unit tests: run the full ApexAgent-UnitTests plan once; report totals. Known-good reference (Oct 20, fix branch): 1,682 run / 1,678 passed / 0 failed / 4 skipped (APEX_LIVE_BOTS-gated, by design). Any failure: failing test names + verbatim assertion lines. Also run SwiftSyntaxLintGateTests on its own and report pass/fail plus whether the working tree was clean when you ran it — it failed on a clean tree on Oct 20 and the skip-on-clean fix is unverified.
4. UI tests: run the ApexAgent-UITests plan in this GUI session. Background: in headless/agent environments every case fails at launchFreshApp (ApexAgentUITests.swift:39, "Application 'com.apexagent.ApexAgent' does not have a process ID"). The open question is whether it works in a real user session like this one. Report totals + verbatim failures. If it hangs more than 10 minutes at app launch, stop it and report exactly where it hung.
5. Crash logs: list ~/Library/Logs/DiagnosticReports entries matching ApexAgent or xctest dated 2026-10-20 or later. For any ApexAgent *app* crash (not xctest), excerpt Process, Exception Type, and the top frames of the crashed thread.
6. Sandbox state: does ~/ApexSandbox exist? `tart list`, `which tart`, `which agy` — presence only, no changes.

PHASE 2 — Deep dive: known-open clusters
For each: verdict FIXED / STILL PRESENT / PARTIAL, file:line evidence, severity.
A. Confirmation-gate bypass cluster (highest priority — trace, don't just grep):
   - confirmationPerformed / confirmation-depth state in AgentOrchestrator.swift: find every read and write. Does the flag remain true through nested delegated sub-agent tool calls, letting a delegated run_shell_command skip its prompt? Trace one nested delegation path end to end and show the evidence.
   - executeToolByName: is there an execution path that bypasses executeWithLogging (repeat detection, disabled-mode check, call cap, sanitization, audit logging)? Show the call-chain evidence.
   - ask_bot and dispatch_swarm: do their tool executions pass through executeWithLogging or skip it?
   - Natural-language regex intercept shims in sendMessage (AgentOrchestrator, ~line 1000) and AgentEngine.swift (~75, ~98) that fire real meetings/delegations from prompt text: list each pattern, what it triggers, and whether any user confirmation stands in between.
B. DynamicToolbox script execution (DynamicToolbox.swift ~222-278): does it still interpolate a manifest path into `/bin/zsh -c "<path>"`? Any allowlist, symlink resolution, or timeout? Compare against the hardened path in MCPClient.executeDynamicScript.
C. Gateway (ApexGatewayServer.swift): do outbound broadcasts iterate ALL connections or only authenticated ones? Does requestRemoteConfirmation have a timeout? Verify the listener is loopback-only and token-gated in code; if the app or a test server is running, [RAN] prove the binding with `lsof -nP -iTCP -sTCP:LISTEN | grep -E '1337|1340'` — otherwise mark the runtime check NOT RUN.
D. GroupChatSession.start() (~128-133): does starting a group chat still reset participants' shared 1:1 sessions? What storage do group-chat turns write to — scoped, or the participants' 1:1 histories?
E. Managers: RoutineManager — verify reset() exists and loadRoutines() is nil-safe (Oct 20 fix). SkillManager: does it repeat the shared-singleton + cached-array pattern? Who reads its cache without re-fetching? ApexCLIRouter: list every read site of the routines cache with line numbers, marking which call loadRoutines() first and which don't.
F. Tool governance exhaustiveness [RAN]: extract the registered tool names (from AgentOrchestrator.allTools / ToolDispatchEngine) and the names with explicit risk levels (AgentSecurity / ToolPolicy); diff the two sets with a script or careful cross-check. Report every mismatch in either direction.
G. Peer approval & playbooks: does any UI render PeerApprovalCoordinator's approval cards? Is expireStale() called anywhere? Can a playbook be RUN from the UI — trace the call chain from a button/menu to PlaybookRunner.execute, or prove none exists. In BotManager.executeCollaborationPlaybook, is a live botManager passed to PlaybookRunner, or does production run simulated?
H. Intents: TriggerRoutineIntent and ExecutePlaybookIntent — do they await and honor the real execution result, or report success unconditionally? For ExecutePlaybookIntent, is botManager injected (live mode) or absent (simulated mode)?

PHASE 3 — Census & hygiene [RAN greps; counts + worst examples]
- TODO/FIXME/HACK: total count + the full list (file:line, text).
- `nonisolated(unsafe)` outside tests: every occurrence, each with a one-line verdict — properly guarded (lock/actor/immutable) or exposed.
- `try!` and `as!` outside tests: counts + the 10 riskiest instances with file:line.
- Force unwraps on external/untrusted input (URL(string:)!, force-unwrapped JSON/dictionary access): sample the worst and judge.
- Secret-literal scan: grep -rniE "(api[_-]?key|password|secret|token)\s*=\s*\"" over app/runtime/module sources, excluding Keychain call sites, labels, and titles. Report hits verbatim with file:line. (Checking for literals only — if you find a real secret value, report its location and variable name, NOT the value.)
- print() count in app sources (debug leftovers).
- Metrics: total Swift LOC (excluding ./build), Swift file count, largest 15 files, test-file count and test-method count per test target.

PHASE 4 — Distribution gates (never verified — settle them)
- Find all .entitlements files; paste their contents. Is com.apple.security.app-sandbox true or false? Any temporary exceptions or disabled-sandbox keys?
- Signing: CODE_SIGN_STYLE, DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY, ENABLE_HARDENED_RUNTIME in project.yml and ApexAgent.xcodeproj/project.pbxproj.
- If a built ApexAgent.app exists (DerivedData or ./build), [RAN] `codesign -dv --entitlements :- <path>` and report: hardened runtime flag present? which entitlements are actually applied?
- Notarization readiness: inventory only — what exists, what's missing. Do not attempt notarization.

PHASE 5 — Docs vs reality
- TASK_MANIFEST.md, TEST_READY.md, README.md, PROJECT.md, SECURITY.md: extract their status claims about tests, features, and security. Mark each TRUE / STALE / FALSE against your Phase 1-4 evidence. Quote the claim; give the verdict; cite the evidence.

REPORT FORMAT — write CODEX_AUDIT_2026-10-22.md with:
1. Ground truth (Phase 1, with numbers).
2. Cluster verdicts A-H (verdict, evidence, severity each).
3. Census results (Phase 3).
4. Distribution gates inventory (Phase 4).
5. Docs-vs-reality table (Phase 5).
6. Your top 10 fix list, ordered by risk, each with file:line and a one-line fix sketch.
7. NOT RUN list — everything you couldn't execute, with reasons.
Then print a chat summary of at most 30 lines: totals, one line per cluster verdict, top 5 fixes.
```

---

**After Codex finishes — Daniel's checklist:**

1. Paste Codex's chat summary back to Monarch in the ApexAgent side chat.
2. Monarch reconciles it against the static audit (`AUDIT_2026-10-22.md`): agreements become confirmed findings, disagreements get investigated before anyone fixes anything.
