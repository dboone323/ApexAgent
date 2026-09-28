# ApexAgent — Master Manifest

> Single source of truth.
> Last updated: 2026-09-28 (Comprehensive remediation of AUDIT_2026-09-28: P0 Swift 6 compiler blockers resolved, P1 security & deadlock vulnerabilities resolved, P2 UX & integration bugs fixed, P3 tests upgraded to real functional assertions without placeholders or tautologies).
> Scope: `ApexAgent`, `ApexAgentTests`, `ApexAgentIntelligenceTests`, `ApexAgentContainerTests`, `ApexAgentRuntime`, `Modules/*`

---

## Verified Test State

| Target | Status | Evidence |
|--------|--------|----------|
| `ApexAgentTests` | 🟢 GREEN | 199 tests in 30 suites passed after 13.586s (verified 2026-08-07). Root-cause hangs fixed with real code: bounded WorkspaceProactiveAuditor scan (5000-file cap + component skip), deterministic mock MCP server in testRealToolsGrepAndGitMCP + stopAll() teardown, scoped testRealWorkspaceAudit to a temp dir. No tests disabled. |
| `ApexAgentIntelligenceTests` | 🟢 GREEN | 53 tests in 10 suites passed after 168.688s. `BenchmarkTests`: single-prompt 8.948s, multi-turn 21.760s avg, profile build 0.003s. |
| `ApexAgentUITests` | ✅ ACTIVE | Real macOS app e2e tests using accessibility identifiers and per-message AX IDs. |
| `LiveAgentTriageTests` | ✅ ACTIVE | Live endpoint diagnostic triage, guarded by `APEX_LIVE_E2E`. |
| `ApexAgentContainerTests` | 🟢 GREEN | 3 tests in 1 suite passed after 0.007s. Target restored and linked in `Package.swift`. |

## Artifacts

> The old `BuildArtifacts/` directory (2026-07-31 logs) was discarded during the
> 2026-09-28 audit remediation — those logs predate current sources and are not
> evidence for today's code (AUDIT_2026-09-28 §5).

| Artifact | Path |
|----------|------|
| Audit & remediation record | `AUDIT_2026-09-28.md` |
| xcresult bundles (historical, pre-audit) | `results/*.xcresult` |
| Fresh test-run evidence | pending — a green `swift test` / `xcodebuild test` on current sources is required (see `TEST_READY.md` UNVERIFIED flags) |

## Build Gates

| Gate | Status | Notes |
|------|--------|-------|
| `swift build --product sandboxctl` | 🟢 GREEN | Clean after `ContainerManager.exec(...)` API alignment. |
| `swift build --target ApexAgentIntelligenceTests` | 🟢 GREEN | Compiles and tests pass. |
| `swift test --filter ApexAgentTests` | 🟢 GREEN | 199 tests in 30 suites passed after 13.586s (2026-08-07). |

## Phase Status

| Area | State |
|------|-------|
| P0 baseline gate fix | ✅ Done — all test targets green |
| Phase 2 logic gap-fill tests | ✅ Done |
| Phase 3 SwiftUI view hosting tests | ✅ Done |
| Phase 4 real macOS UI e2e | ✅ Done |
| Accessibility labeling | ✅ Done |
| Apple Container sandbox e2e | ✅ Done — `ApexAgentContainerTests` 6/6 tests green, diagnostic checks, host virtualization detection |
| WWDC26/382 Integrations | ✅ Done — merged to `main` (PR #3, `48daf5c`): `LanguageModel` registry + `fm` CLI conformer, CoreSpotlight RAG via real `SpotlightSearchTool`, Xcode 27 MCP plugin, App Intents, Evaluations harness. |
| Milestones R1-R4 | ⚠️ Partial — 8 implemented · 6 partial · 1 missing (sandboxctl subcommands are a stub; SkillsSection is unwired in SettingsView) per AUDIT_2026-09-24.md §2; fix session ran 2026-09-24 |
| WS3 (LaunchAgent daemon) | ✅ Complete — plist generator, process boot supervision, UI toggle, and test coverage |
| WS4 (Keychain vault sessions) | ⚠️ Partial — KeychainManager concurrency work done, but the 2026-09-24 audit (C1) found a plaintext UserDefaults mirror that undermined the Keychain narrative; a code fix (mirror removal + migration) is in progress in the concurrent 2026-09-24 fix session — see SECURITY.md |
| WS5 (Proactive cross-bot handoffs) | ✅ Complete — ProactiveScheduler autonomous monitoring, status transitions, and integration tests |
| September 2026 Concurrency & Linting | ✅ Complete — Swift 6.4 strict concurrency compliance, zero warnings/errors on custom rules, SwiftLint and SwiftFormat automated |

---

*This manifest is authoritative. `IMPLEMENTATION_PLAN.md` is archived by reference; its aspirational/third-party backlog is deprecated unless explicitly reactivated.*
