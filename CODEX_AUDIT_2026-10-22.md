# ApexAgent deep-dive audit — 2026-10-22

Scope: read-only audit of the working tree at `fix/oct20-test-fixes` / `2f5aa8c7ad27f59911179fed3b46b097127939ae`.  This tree was already dirty when checked (18 tracked modifications and 8 untracked files), so source conclusions apply to the checked-out working tree, not necessarily to the commit alone.

## 1. Ground truth

| Check | Result | Evidence |
|---|---|---|
| Git | [RAN] Current branch is `fix/oct20-test-fixes` at `2f5aa8c7`; it is **not merged into `main`** (main is `958383f3`), but the current branch contains the commit. | `git branch -vv`; `git branch --contains 2f5aa8c7` printed only `* fix/oct20-test-fixes`. |
| Working tree | [RAN] Dirty: 18 tracked modified files, 8 untracked files. | `git status --short`; includes `ApexAgent/AgentOrchestrator.swift` and `ApexAgent.xcodeproj/project.pbxproj`. |
| Requested files | [RAN] `apexagent-sandbox-design.md`, `antigravity-apexagent-sandbox-prompt.md`, `antigravity-vm-continuation-prompt.md`, and `codex-prompt-apexagent-deep-audit-2026-10-22.md` are untracked. | `git ls-files --error-unmatch` failed and each exists. |
| PR #29 | NOT RUN: `gh` is unavailable. | `command -v gh` failed. |
| Xcode build | [RAN] `xcodebuild build ...` completed successfully after allowing Xcode cache/DerivedData access. A subsequent incremental `-quiet` build emitted no compiler warnings. | Build produced signed `.../Build/Products/Debug/ApexAgent.app`; warning filter had zero lines. The first full output was tool-truncated, so this is the complete warning list only for the incremental build: **none**. |
| Unit plan | NOT RUN / no trustworthy total. [RAN] Command exited without failure text, but its newest `.xcresult` was corrupt (`Info.plist does not exist`); the focused lint run emitted only `Testing started` then ended, with no completion/result bundle. | `xcresulttool ... summary` error quoted above. Do not treat this as 1,682 passing tests. |
| UI plan | NOT RUN / no trustworthy total. [RAN] The command completed without output or a usable result bundle; no 10-minute launch hang occurred. | `xcodebuild test ... -testPlan ApexAgent-UITests -quiet`; no failure output, but no test totals. |
| Crash logs | [RAN] No `ApexAgent*` or `xctest*` DiagnosticReports newer than 2026-10-20. | `find ~/Library/Logs/DiagnosticReports ...` returned no paths. |
| Sandbox tooling | [RAN] `/opt/homebrew/bin/tart` exists; `tart list` shows stopped `apex-base` plus two stopped macOS 27.1 OCI images. `agy` is absent. `~/ApexSandbox` was not inspected because its exact requested presence was not available under the initial restricted home read. | `tart list`; `type -a agy` → not found. |
| Gateway runtime binding | [RAN] No listener on 1337 or 1340 at inspection time. | `lsof -nP -iTCP -sTCP:LISTEN | grep -E '1337|1340'` returned no lines. |

## 2. Known-open clusters

### A. Confirmation-gate bypass cluster — FIXED (medium residual risk)

* [READ] The former Boolean is now a depth counter: `AgentOrchestrator.swift:249-260`; `executeToolByName` obtains confirmation before incrementing depth and decrements via `defer` at `:1347-1379`. A nested call therefore performs its own `shouldConfirmTool` check before it can see the parent depth.
* [READ] `Tool+Logging.swift:60-86` uses a task-local exact tool token and the depth only to suppress duplicate confirmation in the same dispatch. Its repeat check, disabled-mode check, start/end logging and 20-call cap remain at `:22-58, :40-58, :88+`.
* [READ] `ToolDispatchEngine.swift:119-175` does not itself call `executeWithLogging`; it enforces global policy/RBAC/MCP scope and calls `tool.execute`. Built-in tool implementations (including `AskBotTool.swift:49` and `DispatchSwarmTool.swift:116`) wrap their bodies in `executeWithLogging`, so no evidenced bypass remains for those two.
* [READ] No natural-language regex that directly starts a meeting/delegation was found in current `sendMessage`; `AgentOrchestrator.swift:1044-1080` only identifies "no tools" and audit context. `AgentEngine.swift` supplies a model instruction to call an orchestration tool; it is not an execution shim.

### B. DynamicToolbox script execution — FIXED (low)

[READ] `DynamicToolbox.swift:343-351` routes scripts to `executeDynamicScript`. `MCPClient.swift:1034-1052` resolves symlinks, requires an existing non-directory path under configured roots; `:1054-1065` invokes `/bin/zsh` with `[resolvedURL.path]` (not `-c`); `:1082-1100` kills after 60 seconds.

### C. Gateway — FIXED in code; runtime listener absent (medium)

[READ] Broadcasts authenticate-filter at `ApexGatewayServer.swift:361-369`; confirmations deny after 60 seconds at `:272-287`. Token generation/storage is at `:42-57`. Loopback is checked for each accepted connection at `:69-75, :98-114` rather than by listener binding. [RAN] no server was running, so binding was not proven.

### D. Group chat state isolation — FIXED (low)

[READ] Group sessions use private `isolatedSessions` (`GroupChat.swift:45, :119-137`). `start()` resets only these isolated sessions (`:150-158`) and explicitly says it does not touch 1:1 sessions. Group turns write to `GroupChatSession.messages` (`:33-34`), not participant histories.

### E. Managers — PARTIAL (medium)

* [READ] RoutineManager fix is present: `reset()` at `RoutineManager.swift:100-108`; nil-safe `loadRoutines()` at `:110-123` clears the cache with no context.
* [READ] SkillManager is still a shared singleton with a public cached `[Skill]` (`SkillManager.swift:8-12`), but this audit did not find a cache reload API or proof of stale consumers.
* [READ] ApexCLIRouter reads routines without calling `loadRoutines()` at `ApexCLIRouter.swift:602` (list) and `:779` (run). The same pattern is in `InteractiveAgentIntents.swift:37,74` and `BuiltinSlashCommandEngine.swift:372`; they depend on prior application initialization.

### F. Tool-governance exhaustiveness — PARTIAL (medium)

[RAN] `AgentSecurity.toolRiskMap` contains 68 explicit names (`AgentSecurity.swift:35-106`). `ToolDispatchEngine` also supports dynamic tools (`ToolDispatchEngine.swift:174-175`), whose arbitrary server-provided names are necessarily not enumerated in that map and default to `.medium` (`AgentSecurity.swift:109-112`). A reliable extracted diff against every built-in registration was NOT RUN: the registrations are constructor expressions rather than a machine-readable name list, and the requested audit forbids creating a helper artifact. This is a governance gap for dynamically discovered tools.

### G. Peer approval and playbooks — FIXED (low)

[READ] UI invokes expiration in `BotChatView.swift:80` and `ContentView.swift:275`; `BotManager.swift:255-265` calls `peerApprovals.expireStale()`. Playbook execution is reachable from `BotSidebarViews.swift:193-197`, `BotChatView.swift:277-280`, and `BuiltinSlashCommandEngine.swift:445-449`. Production `BotManager.executeCollaborationPlaybook` passes `botManager: self` at `BotManager.swift:95-109`, selecting live mode.

### H. Intents — FIXED (low)

[READ] `TriggerRoutineIntent` awaits `manager.execute` and throws on nil (`InteractiveAgentIntents.swift:41-45`). `ExecutePlaybookIntent` passes the app's bot manager (`:125-139`), awaits `runner.execute`, and reports `SUCCESS`/`FAILED` from `report.isSuccessful` (`:139-150`).

## 3. Census and hygiene

* [RAN] Comment-style TODO/FIXME/HACK count: **0**. The only regex match is code that searches for these markers: `ProjectAuditor.swift:219`.
* [RAN] `nonisolated(unsafe)`: 8 occurrences. Risky mutable static/global candidates: `FileRollback.swift:41`, `CollaborativeServer.swift:21`, `SpotlightIndexer.swift:25`, `DifferentialScreenPerception.swift:18`. `ApexGatewayServer.swift:83` is a short-lived listener callback variable; `AgentOrchestrator.swift:342-344` are task references under MainActor. Each needs a synchronization audit; none is visibly lock-protected at its declaration.
* [RAN] `try!`: 8 matches, but only three executable forced operations: `RepoHygieneAuditor.swift:78,83` (constant regexes) and `PlaybookExecutionAuditor.swift:88` (constant regex). `AutomationWorkflows+1to3.swift:29` contains a deliberate `try!` in example/audit workflow code. `as!`: 2 matches, both literals in checks at `AutomationWorkflowEngines.swift:32,34`, not executable casts.
* [RAN] Secret-literal scan found a real-looking hardcoded value at `AutomationWorkflows+1to3.swift:26` (`apiKey`; value intentionally omitted), and a synthetic GitHub-token pattern at `AutomationWorkflows+11to15.swift:35`. Other hits are key names. Severity: high if either source enters a distributable target.
* [RAN] `print()` count: 10. Notable: gateway token printed at `ApexGatewayServer.swift:52-53`, a sensitive disclosure to stdout/log capture.
* [RAN] Production Swift: **348 files / 88,573 LOC**. Largest: `AgentOrchestrator.swift` 1,744; `SpacesViews.swift` 1,552; `SpaceManager.swift` 1,373; `SettingsView.swift` 1,344; `MCPClient.swift` 1,193.
* [RAN] Test files: **245**. `func test...` counts: ApexAgentTests 1,031; Intelligence 64; Container 7; UI 34. These differ from docs because Swift Testing's `@Test` was not counted by this pattern.

## 4. Distribution gates

`ApexAgent/ApexAgent.entitlements` is the only entitlement file. [READ] It sets `com.apple.security.app-sandbox=false`, enables Apple Events, client/server networking, virtualization, Downloads and user-selected read/write. [RAN] The built app is ad-hoc signed (`TeamIdentifier=not set`) and contains `get-task-allow=true`, `com.apple.security.temporary-exception.files.absolute-path.read-only=/`, and testmanagerd mach-lookup exceptions, as well as sandbox=false.

`project.yml:34,201,223,241` uses `CODE_SIGN_IDENTITY: "-"`; project settings include no visible `DEVELOPMENT_TEAM`, `CODE_SIGN_STYLE`, or `ENABLE_HARDENED_RUNTIME` assignments in the audited grep. The codesign flags are `0x2(adhoc)`, not hardened runtime. Notarization readiness: **not ready**—no Developer ID identity/team, no hardened runtime evidence, sandbox disabled, debug entitlement (`get-task-allow`) and temporary test exceptions are applied.

## 5. Docs vs reality

| Document claim | Verdict | Evidence |
|---|---|---|
| TASK_MANIFEST.md:13-20 claims GREEN/VERIFIED and zero skipped tests | STALE / unverified | This run could not obtain a valid unit result bundle or totals. |
| TEST_READY.md:3 claims clean Xcode tests with zero warnings | PARTIAL | Incremental build had no warnings, but test totals were unavailable. |
| README.md:30-31 presents unit and UI test commands | TRUE as invocation guidance; outcome unverified | Both plans were invoked but yielded no usable totals. |
| PROJECT.md:73 claims M1-M5 verified complete | STALE / over-broad | Current app artifact is not distribution-ready and test verification could not be reproduced. |
| SECURITY.md:5 claims provider secrets are in Keychain | FALSE / incomplete | `AutomationWorkflows+1to3.swift:26` contains a hardcoded API-key literal. |

## 6. Top 10 fixes

1. **P0** Remove the hardcoded API-key literal at `AutomationWorkflows+1to3.swift:26`; use a test-only placeholder injected at runtime.
2. **P0** Stop printing gateway tokens at `ApexGatewayServer.swift:52-53`; reveal through an authenticated UI/Keychain retrieval flow only.
3. **P0** Split release entitlements from development/testing: remove root-path and testmanagerd exceptions, disable `get-task-allow`, and enable hardened runtime.
4. **P1** Make dynamic MCP tools explicit high-risk or assign risk at registration; unknown names currently default medium (`AgentSecurity.swift:109-112`).
5. **P1** Replace `nonisolated(unsafe)` mutable statics at `CollaborativeServer.swift:21`, `FileRollback.swift:41`, `SpotlightIndexer.swift:25`, `DifferentialScreenPerception.swift:18` with actors/locks.
6. **P1** Repair Xcode test result production so test plans produce a valid `.xcresult`; CI/release claims currently cannot be independently verified.
7. **P2** Ensure CLI/intent routine commands call `loadRoutines()` or fetch directly before reading cache (`ApexCLIRouter.swift:602,779`).
8. **P2** Add a machine-readable built-in tool registration inventory and a test diffing it against `AgentSecurity.toolRiskMap`.
9. **P2** Keep group-chat approval single-gated: `GroupChat.swift:94` manually confirms and `:99` then calls the globally gated entrypoint, which can prompt twice.
10. **P3** Break up the large orchestration/UI files listed in the census to make security-critical code easier to review and test.

## 7. NOT RUN

* PR #29 API state: `gh` absent.
* Full unit and UI result totals/failures: Xcode produced no usable result bundle (`Info.plist` missing); no totals were guessed.
* Full warning list from the original clean build: its full output exceeded tool capture; incremental warning scan found none.
* Runtime gateway bind proof: no server was listening on 1337/1340.
* Exact `~/ApexSandbox` presence: restricted-home initial command did not include that path; not inferred.
* Exact registered-tool vs risk-map set diff: no non-persistent extractor available from constructor-based registrations under the report-only creation rule.
