# Codex fix pass — ApexAgent, 2026-10-22

You audited this repo earlier today (`CODEX_AUDIT_2026-10-22.md`). A second,
independent static audit (`AUDIT_2026-10-22.md`, repo root) covered the same
tree. This pass implements the reconciled fix list from BOTH reports, in
priority order. Both audit reports are in the repo root — treat their
file:line evidence as ground truth; line numbers may have drifted slightly,
so locate by symbol when an anchor doesn't match and note any drift.

For each fix you get: the problem with evidence, a PROPOSED FIX, and how to
verify it. **The proposed fixes are a starting plan, not gospel — you are the
second opinion.** Before applying each one, check it against the actual code.
If a proposal is wrong, incomplete, or there's a clearly better approach,
implement the better approach instead and flag the deviation prominently in
your report. If a proposal would break something the audits didn't see, stop
that fix, revert its edits, and report why.

## Hard rules

- Work in the current working tree on the current branch. **No commits, no
  branch switches, no pushes.** The tree starts dirty (18 pre-existing
  modifications that are NOT yours) — never revert, reformat, or "clean up"
  work you didn't do in this pass.
- One fix at a time, in the order given. After each fix: build, then run the
  focused tests named in its Verify step. If a fix leaves the build or its
  focused tests red and you can't repair it within that fix's scope, revert
  ONLY that fix's edits, mark it REVERTED with the reason, and move on.
  Never leave the tree broken for the next fix.
- Tests: you may ADD tests. You may NOT weaken, delete, skip, or edit an
  existing test to make it pass. If an existing test demonstrably encodes the
  buggy behavior a fix corrects, stop that fix and flag it — don't touch the
  test.
- No new dependencies. No public-API changes beyond what a fix requires.
- Several questions are DECISIONS RESERVED for the repo owner (marked
  DECISION in the fixes). Do not decide them; implement everything around
  them and list them in the report.
- Write your report to `CODEX_FIXES_2026-10-22.md` in the repo root —
  the ONLY new file you create besides tests. Per fix: status (APPLIED +
  VERIFIED / APPLIED, UNVERIFIED / REVERTED / SKIPPED + why), what you
  actually changed (files), where you deviated from the proposal and why,
  and the verification evidence (test names and counts).

## Phase 0 — checkpoint

1. Record `git status --short` and `git diff --stat` in the report verbatim.
   This is the baseline you must be able to distinguish your edits from.
2. Confirm the tree builds before you touch anything. If it doesn't, stop
   and report — do not fix a pre-existing break inside this pass unless it
   blocks F1–F3, in which case report it as its own finding first.

---

## F1 (P0) — Remove the hardcoded API-key literal

**Problem** (your audit §3): `AutomationWorkflows+1to3.swift:26` assigns a
real-looking literal to `apiKey`; `AutomationWorkflows+11to15.swift:35`
contains a GitHub-token-shaped pattern. `SECURITY.md` claims provider
secrets live in Keychain — these literals make that claim false.

**Proposed fix:** Replace both literals with an obviously-fake placeholder
injected at runtime: read from the process environment
(`ProcessInfo.processInfo.environment[...]`) with a placeholder fallback
string like `"REPLACE_WITH_TEST_KEY"`, following whatever pattern these
workflow files already use for other injected values. First determine
whether these files are app-target code or example/template content and say
which in the report — if template, the placeholder must be unmistakably a
placeholder. Do NOT print, log, or copy the original values anywhere,
including your report; refer to them by file:line only.

**Verify:** grep for the literal patterns afterward (your secret-scan
regexes from the audit) returns no real-looking hits; build green.
**DECISION (owner):** whether the F1 key was ever a live credential
(rotation) is the owner's call — flag it in the report, don't act on it.

## F2 (P0) — Stop printing the gateway token

**Problem** (your audit §3): `ApexGatewayServer.swift:52-53` prints the
gateway token to stdout, where it lands in log capture.

**Proposed fix:** Delete the token value from the print. If a first-run
notice is genuinely needed, log only that a token was generated and that it
is stored in Keychain — never the value. Check the file's other `print`
calls while you're there (10 in the codebase per your census) and strip any
other secret values the same way; list any you touch.

**Verify:** grep the gateway file for the token variable in output
statements — none remain; build green.

## F3 (HIGH — the #1 code fix) — Wire the confirmation gate to the risk map

**Problem** (static audit, its top new finding): the live gate
`shouldConfirmTool` consults only a hardcoded 5-tool set. ~20 tools
classified `.high` in `AgentSecurity.toolRiskMap` — computer_use, github,
discord_bot / discord_webhook, manage_sandbox, simctl, mail_automation,
deep_link, control_browser, execute_dynamic_tool among them — get NO
confirmation prompt by default. The classification work (your F: 68 names
in `AgentSecurity.swift:35-106`) was never wired to enforcement. Unknown /
dynamically discovered names default to `.medium`
(`AgentSecurity.swift:109-112`) and also sail through. The static audit
also notes an `AgentSecurity.requiresConfirmation` symbol whose live
callers are unverified — check whether the map-side API already exists.

**Proposed fix:**
1. First, produce the census the audit skipped: extract every registered
   built-in tool name and diff it against `toolRiskMap` keys. (Counts on
   record disagree — yours 68, static audit 78, README 70.) Classify any
   registered-but-unclassified tool by what it actually does; list every
   addition in the report.
2. Make the gate consult the map: a tool requires confirmation when its
   classified level is `.high`, OR it appears in the existing hardcoded
   set (keep the old set as a floor — union, don't replace), OR it is
   unclassified / dynamically discovered (fail closed). If
   `AgentSecurity.requiresConfirmation` exists, prefer wiring the gate
   through it so there's one source of truth.
3. Keep the DEBUG auto-approve behavior exactly as-is — it's a deliberate
   design decision, not part of this fix.

**Verify:** add a unit test that iterates the classified `.high` set and
asserts the gate requires confirmation for each (under whatever seam the
gate exposes; if none exists, a narrow testable helper is in scope).
Focused suites: ToolGovernanceTests + the orchestrator/logging tests.
Census result (registered count, map count, additions) in the report.
**Watch out:** anything that legitimately depends on the old 5-tool-only
behavior — surface it as a deviation, don't silently preserve it.

## F4 (P1) — Close the remaining enforcement gaps (Path B, bypass tools, suppression scope)

**Problem** (both audits): `ToolDispatchEngine.executeToolByName`
(`ToolDispatchEngine.swift:119-175`) has no safeguard stack of its own —
no confirmation, repeat check, cap, or audit logging for anything that
reaches it directly. Three tools bypass `executeWithLogging` on every
path: CaptureWindowImage, AccessibilityOmniTargeter,
DifferentialScreenPerception. And the nested-suppression logic
(`Tool+Logging.swift:60-86` task-local token + depth counter,
`AgentOrchestrator.swift:249-260`, `:1347-1379`): a DIFFERENT tool invoked
directly inside an outer frame can still inherit `confirmationDepth > 0`
and skip its own confirmation.

**Proposed fix:** One enforcement point: every route that reaches
`tool.execute` passes the same stack — confirmation (per F3), repeat
check, 20-call cap, start/end logging. Route `executeToolByName` through
the same entry built-ins use, or give it the identical stack; wrap the
three bypass tools' bodies in `executeWithLogging` like `AskBotTool.swift:49`
and `DispatchSwarmTool.swift:116`. Scope the duplicate-suppression so it
only suppresses a repeat confirmation for the SAME tool within the SAME
dispatch — never a different tool riding an outer frame's depth.

**Verify:** trace every caller of `executeToolByName` and every direct
`tool.execute` call site; list them in the report with the gate each now
passes. Add/extend tests where a seam exists; run the full unit plan at
the end of the pass (final phase) and compare against baseline counts.

## F5 (P1) — Routine cache reads must load before reading

**Problem** (both audits; long-standing queue item): these sites read
`RoutineManager.shared.routines` without ensuring `loadRoutines()` ran:
`ApexCLIRouter.swift:602` and `:779`, `InteractiveAgentIntents.swift:37`
and `:74`, `BuiltinSlashCommandEngine.swift:372`. `RoutineManager` itself
is already fixed (`reset()` `:100-108`, nil-safe `loadRoutines()`
`:110-123`) — the consumers never got the same discipline. Symptom class:
empty/stale routine lists depending on app initialization order (and this
pattern caused a past test-process crash via the shared singleton).

**Proposed fix:** at each site, ensure the cache is loaded in the current
context before the read — call `loadRoutines()` first, following how the
app itself initializes the manager; if a site's context makes that unsafe
(non-main, no context injected), fetch through the manager's own API
instead and note the choice per site.

**Verify:** ApexCLIRouterTests + routine tests green; per-site note in
the report of which approach each site took and why.

## F6 (P1) — SkillManager: stop the sync data loss, populate the cache

**Problem** (static audit): `SkillManager.syncFromDisk()` DELETES the
procedural (non-file-backed) skills it claims to preserve, and the
`skills` cache (`SkillManager.swift:8-12`) is never populated —
`enabledSkills` / `skill(named:)` are silently dead. This is the
RoutineManager twin risk, inverted: not stale reads, a cache that's
always empty plus a sync that destroys data.

**Proposed fix:** make `syncFromDisk()` merge, not replace: file-backed
skills refresh from disk, procedural skills survive untouched. Populate
the cache from the same fetch the UI uses, so the lookup APIs work.
Find `syncFromDisk` callers first (unverified until now) and list them.

**Verify:** add a test: seed a procedural skill, run sync, assert it
survives; assert `skill(named:)` returns a disk-backed skill after load.
Skills tests green.

## F7 (P1) — Replace the risky `nonisolated(unsafe)` mutable statics

**Problem** (your audit §3): 8 occurrences; four are mutable shared state
with no visible synchronization: `FileRollback.swift:41`,
`CollaborativeServer.swift:21` (the rate-limiter storage),
`SpotlightIndexer.swift:25`, `DifferentialScreenPerception.swift:18`.

**Proposed fix:** per site, following the precedent already in this
codebase (AgentRegistry's Mutex fix): wrap the storage in
`Mutex` / `OSAllocatedUnfairLock`, or move it into an actor if the access
pattern allows without cascading signature changes. Smallest change per
site; if a site's access pattern makes the minimal fix unsafe, leave it
and report it as a design item instead of forcing it. The remaining 4
occurrences: inspect, fix if same class, otherwise list as reviewed-OK
with one line each on why.

**Verify:** build + full unit plan comparison; per-site note.

## F8 (P1) — Split release entitlements from development entitlements

**Problem** (your audit §4): the single `ApexAgent.entitlements` is used
for the shipped artifact: `app-sandbox=false`, built app ad-hoc signed
with `get-task-allow=true`, a root-path read-only temporary exception
(`/`), and testmanagerd mach-lookup exceptions. `project.yml`
(`:34,201,223,241`) uses `CODE_SIGN_IDENTITY: "-"`; no team, no hardened
runtime anywhere. Notarization is impossible in this configuration.

**Proposed fix:** split entitlements into Debug and Release files wired
per-configuration (via project.yml / XcodeGen, following the project's
existing structure). Release loses: `get-task-allow`, the root-path
exception, the testmanagerd exceptions. Enable hardened runtime for
Release. First inventory which entitlements the app genuinely needs at
runtime (virtualization for the VM features, Apple Events, networking,
Downloads / user-selected file access) and keep exactly those in Release
— list kept vs dropped with reasons.
**DECISION (owner):** whether Release flips `app-sandbox` to true is NOT
yours — it changes what the app can do. Leave sandbox=false in Release,
flag it as the owner's decision in the report, and note what breaks if
flipped, if you can tell from the code. Likewise the Developer Team ID:
leave a clearly-marked placeholder, don't invent one.

**Verify:** build BOTH configurations; `codesign -d --entitlements :-`
on the Release artifact shows the cleaned set; paste that output in the
report.

## F9 (P2) — Stop fabricating status in intents and the Xcode plugin

**Problem** (static audit): `InspectAgentStatusIntent` returns a
hardcoded "ApexAgent Status: ONLINE" regardless of reality. The Xcode
plugin's `run_agent_task` / `ask_apex_agent` return success
acknowledgements (`isError: false`) while executing nothing.

**Proposed fix:** report reality or admit ignorance: have the intent
query the app's actual state (bot manager / orchestrator availability)
and phrase the result from that; where no real signal exists, return an
explicit "status unavailable" rather than ONLINE. For the plugin tools:
if they cannot execute, return `isError: true` with a plain explanation
instead of a success ack. (Compare `InteractiveAgentIntents.swift:41-45`
and `:125-150` — the two intents that already await and honor real
results are the pattern to match.)

**Verify:** intents tests green; note in the report what real signal the
status now reads.

## F10 (P2) — Get the collab token out of the invite URL; make collab RBAC real

**Problem** (static audit, long-standing): `SpaceManager.swift:500`
embeds the collab token in the invite URL query string (URLs get logged,
shared, screenshotted), the server still accepts tokens via query string,
and collab RBAC is decorative: loopback is exempt and `hasPermission`
ignores the permission it's asked about.

**Proposed fix:** map the full invite-redemption flow first. Preferred
end state: the URL carries a one-time invite code, redeemed for the
token over the authenticated channel (request body/header), and the
server stops accepting query-string tokens. If that's too invasive for
one pass, do the staged version — client sends the token in a header,
server accepts header AND query with the query path marked deprecated —
and say clearly that the query path remains open (don't claim the hole
closed if it isn't). Separately, make `hasPermission` actually evaluate
the requested permission; keep the loopback exemption only if a comment
in code justifies it, and flag it in the report either way.

**Verify:** collaboration server tests green (note: one test
authenticates with `Authorization: Bearer` — keep that path working);
describe a manual join using a fresh invite in the report if you ran one.

## F11 (P2) — Group chat double confirmation

**Problem** (your audit fix #9): `GroupChat.swift:94` manually confirms,
then `:99` calls the globally gated entrypoint, which can prompt a
second time under the F3/F4 stack.

**Proposed fix:** remove the manual confirmation; the gated entrypoint
owns confirmation. (Legacy engine, Spaces is the strategic surface —
keep this fix minimal, don't invest beyond the double-prompt.)

**Verify:** build green; one-line note.

## F12 (P2) — Playbook determinism and approval surfaces (largest item — bounded)

**Problem** (static audit): parallel playbook stages still collapse
multiple roles onto one bot and collect results in completion order —
nondeterministic output, nil turns possible. Peer-approval cards render
only inside the sender bot's 1:1 view and `ask_bot` doesn't pause/resume
on an approval; playbook approval cards show only the last runner's card,
only in a 1:1 chat. The plumbing underneath all works (live bot manager
is passed, `BotManager.swift:95-109`; `expireStale()` is called).

**Proposed fix, in this sub-order:**
1. Determinism first: parallel stage results keyed by role/bot and
   reassembled in stage definition order; a role that can't be staffed
   produces an explicit failed/unstaffed turn, never a silent nil.
2. Surfaces second, minimal version: approval cards render in the
   conversation where the playbook/ask originated, not only a 1:1 view.
If either part balloons into a redesign of the playbook engine or the
chat UI, STOP that part, revert it, and write a short design note in the
report instead — a correct partial beats a forced rewrite.
**DECISION (owner):** the legacy group-chat engine's fate (wire a
reachable UI vs remove in favor of Spaces) is not part of this fix.

**Verify:** playbook tests green + a new determinism test (same stage
set, run twice, identical ordered output) if a seam exists.

## F13 (P3) — Make the docs tell the truth

**Problem** (both audits): TASK_MANIFEST claims GREEN/VERIFIED with zero
skips; TEST_READY claims clean tests, zero warnings; PROJECT claims
M1–M5 verified complete; README cites 70 tools and test commands whose
outcomes are unverified; the docs' test counts (103 files / 85 in
ApexAgentTests) are wrong — disk shows ~245 test files total, 227 in
ApexAgentTests alone. SECURITY.md claims secrets are Keychain-only.

**Proposed fix:** AFTER the final verification phase below, rewrite the
claims to match the evidence you actually produced in this pass:
real test totals (including skips), real warning count from the clean
build, the F3 census tool count, distribution status as "not ready"
with the F8 state, and SECURITY.md corrected for how workflow files
inject keys post-F1. Where a number couldn't be verified, the doc says
so instead of claiming it.

---

## Final verification phase (mandatory, after F1–F13)

1. **Clean build** with the full log captured to a file (no truncation):
   report the exact warning list, or state zero with the log as evidence.
   Incremental "no warnings" does not count.
2. **Unit test plan** with an explicit `-resultBundlePath`; report totals
   from `xcresulttool` (run / passed / failed / skipped, failed names).
   If the bundle is again corrupt or missing, that is a finding — say so
   plainly, do not estimate totals. (The last verified baseline on this
   branch: 1,682 run / 1,678 passed / 0 failed / 4 skipped, three
   consecutive runs, 2026-10-20. Compare against it and explain any delta,
   including tests added in this pass.)
3. **SwiftSyntaxLintGate** run solo on the resulting tree (its fix is in
   the tree but unverified) — report pass/fail as-is.
4. **UI test plan:** attempt it; if it fails at app launch in this
   environment (the known harness limitation), record that as NOT RUN
   with the exact failure — do not retry-loop it.
5. Close the report with: fixes by status; every deviation from the
   proposals and why; DECISIONS RESERVED list (F1 key rotation, F8
   sandbox flip + team ID, F12 group-chat engine fate); the NOT DONE
   list — anything from the two audit reports this pass didn't reach.

Begin with Phase 0.
