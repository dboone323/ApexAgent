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
| Apple Container sandbox e2e | 🟡 Build gate fixed; `ApexAgentContainerTests` green; runtime container boot pending hardware/entitlement verification |
| WWDC26/382 Integrations | ✅ Done — merged to `main` (PR #3, `48daf5c`): `LanguageModel` registry + `fm` CLI conformer, CoreSpotlight RAG via real `SpotlightSearchTool`, Xcode 27 MCP plugin, App Intents, Evaluations harness. MLX/`LanguageModel` executor path still blocked by a macOS 27 beta `LanguageModelSession()` SIGSEGV (Apple bug; `MLXAgentEngine` direct-HTTP is the working path). |

## Next Actions (from NEXT_STEPS.md)

1. **WS4 Observability** — implement structured tracing via swift-log + Tracing module + instrument Delegation/MCP/Orchestrator + `/api/traces` + metrics.
2. **WS6 MCP Resilience** — timeouts, backoff, health/circuit-breaker, process supervision, structured logging.
3. **WS1 Generic Multi-Agent (pure-Swift pieces)** — AgentHandoff DTOs, AgentRegistry, DelegateTaskTool/ConveneMeetingTool refactor.
4. Capture XCUITest logs from `/tmp/xcb*.log` and `xcresult`.
5. Continue Apple Container runtime verification on hardware with virtualization entitlement available.

---

*This manifest is authoritative. `IMPLEMENTATION_PLAN.md` is archived by reference; its aspirational/third-party backlog is deprecated unless explicitly reactivated.*
