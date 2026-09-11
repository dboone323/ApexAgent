# ApexAgent — Master Manifest

> Single source of truth.
> Last updated: 2026-08-07 (P0 ApexAgentTests gate fixed — 199 tests/30 suites green in 13.6s; stale branch cleanup)
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

| Artifact | Path |
|----------|------|
| `ApexAgentTests` green run | `BuildArtifacts/2026-07-31_ApexAgentTests_green.md` |
| Full `swift test` run | `BuildArtifacts/2026-07-31_full_swift_test.md` |
| `ApexAgentContainerTests` green run | `BuildArtifacts/2026-07-31_ApexAgentContainerTests_green.md` |
| `ApexAgentIntelligenceTests` green run | `BuildArtifacts/2026-07-31_ApexAgentIntelligenceTests_green.md` |
| `BenchmarkTests` timing evidence | `BuildArtifacts/2026-07-31_benchmark_timings.md` |

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
| Milestones R1-R4 | ✅ Complete |
| WS3 (LaunchAgent daemon) | ✅ Complete — plist generator, process boot supervision, UI toggle, and test coverage |
| WS4 (Keychain vault sessions) | ✅ Complete — KeychainManager with Synchronization.Mutex concurrency safety and credentials storage |
| WS5 (Proactive cross-bot handoffs) | ✅ Complete — ProactiveScheduler autonomous monitoring, status transitions, and integration tests |
| September 2026 Concurrency & Linting | ✅ Complete — Swift 6.4 strict concurrency compliance, zero warnings/errors on custom rules, SwiftLint and SwiftFormat automated |

---

*This manifest is authoritative. `IMPLEMENTATION_PLAN.md` is archived by reference; its aspirational/third-party backlog is deprecated unless explicitly reactivated.*
