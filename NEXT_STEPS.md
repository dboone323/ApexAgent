# ApexAgent — NEXT STEPS (Reconciled, Policy-Pruned Roadmap)

> **Authoritative source of truth:** `TASK_MANIFEST.md` (90+ items across 5 tiers, all marked `[x]` done). It supersedes all prior audit reports. This document does NOT modify it.
> **`IMPLEMENTATION_PLAN.md` is a CANDIDATE backlog only** — not authoritative. Its `[ ]` checkboxes and "Ready for Execution" status are aspirational proposals, not verified facts. Treat its workstreams below as *recommendations to be approved*, pruned against the user's policy.
> **Policy basis:** strict scope = ApexAgent + Shared-kit only · free-tier-only (no paid plugins/services) · privacy-first / on-device · credentials in Keychain, never on disk.

---

## 0. Verified Test Status (3 targets, not 4)

| Target | Status | Notes |
|--------|--------|-------|
| `ApexAgentIntelligenceTests` | 🟢 GREEN | 24 pass |
| `ApexAgentContainerTests` | 🟢 GREEN | 4 pass |
| `ApexAgentTests` | 🟢 GREEN | 199 tests in 30 suites passed after 13.586s (2026-08-07). Root-cause hangs fixed with real code, no tests disabled. |
| `ApexAgentRuntime` | n/a | **The app executable** (`.executableTarget`, path `ApexAgentRuntime`). **NOT a test target.** Corrects the plan's implicit "4 test targets" assumption. |

---

## 1. Repo-Ambiguity Resolution (RED FLAG)

`IMPLEMENTATION_PLAN.md` → "Next Steps" instructs:
`gh issue create --repo dboone323/fleet.workspace ...`

- **Actual repo (verified via `git remote -v`):** `dboone323/ApexAgent`
- **Mismatch:** `fleet.workspace` is a *different* repository. Creating issues there would orphan the work from this codebase.
- **Decision:** Create any tracking issues **ONLY in `dboone323/ApexAgent`**. Flag the `fleet.workspace` reference in the plan as a copy-paste error to correct before use.

---

## 2. Ordered, In-Policy Next Workstreams

### P0 — Baseline gate fix (DO FIRST)
- **Fix the hanging `ApexAgentTests` target** so the full suite is green (2 green + this one).
- Why first: `IMPLEMENTATION_PLAN.md`'s Definition of Done requires `swift test` to pass; nothing else can be verified/merged until the suite is reliable. Pure Swift, on-device, in-scope. **Non-negotiable gate.**

### KEEP — Recommended next work (free-tier, on-device, additive, in-scope)
- **WS4 Observability (structured tracing).** 4.1 swift-log (already a declared dep) → 4.2 `Tracing` module → 4.3–4.5 instrument Delegation/MCP/Orchestrator → 4.6 `/api/traces` → 4.7 metrics. Pure Swift, on-device. (W3C `traceparent` is a spec, not a cloud service — fine.)
- **WS6 MCP Resilience.** 6.1 `MCPError`/`MCPClientConfig` → 6.2 timeouts → 6.3 backoff → 6.4 health/circuit-breaker → 6.5 process supervision → 6.6 structured logging. Pure Swift, on-device, directly improves reliability.
- **WS1 Generic Multi-Agent (pure-Swift, additive pieces).** KEEP: 1.1 `AgentHandoff` DTOs, 1.2 `AgentRegistry` (loads `~/.apex/agents/*.json` — on-device), 1.3 `DelegateTaskTool` refactor, 1.4 `ConveneMeetingTool` refactor, 1.5 reconciliation, 1.6 plugin load test. All within ApexAgent + on-device. (1.6's dashboard "Traces" panel depends on WS4 — sequence accordingly.)

### KEEP but CONDITIONAL — WS2 CollaborativeServer Hardening
- LAN-only / localhost auth (2.2 `BearerTokenAuth`/`MTLSAuth`, 2.3 RBAC, 2.4 audit log, 2.5 LAN TLS cert) is **acceptable** — LAN-only is already the audit's stated stance, on-device, free.
- 🚩 **STRIKE any WAN/cloud assumption** (e.g., binding `0.0.0.0` without opt-in, cloud token broker). Keep strictly localhost/LAN with explicit user consent. The plan's own 2.1 audit already requires "no path to `0.0.0.0` without explicit flag" — enforce that.

### CHERRY-PICK CANDIDATES (policy-aligned, could be pulled forward individually)
Under the otherwise-deferred WS5, these are on-device + free + privacy/security-aligned:
- **5.5 Keychain audit log** — aligns with "credentials in Keychain" policy; on-device.
- **5.6 Per-tool allowlist** — privacy/security aligned; on-device.
- **5.7 Write rollback / snapshots** — on-device, free.

### DEFERRED — requires user approval of paid/external service or out-of-policy
- **WS3 Orchestrator → DI refactor** — large, lower-priority; `TASK_MANIFEST` already addressed adjacent items (3.16 `@TaskLocal`, etc.). **DEFERRED** until after P0 + WS4 + WS6. Revisit only if testing pain resurfaces.
- **WS5 Security Hardening (workstream-level)** — **DEFERRED** (except the cherry-picks above). Specifically struck:
  - **5.2 Hardened Runtime + Notarization CI (`notarytool` + GitHub Actions)** — ❌ **STRIKE: requires paid Apple Developer account + external CI.** "DEFERRED — requires user approval of paid/external service."
  - 5.3 / 5.4 entitlement-drift & JIT guards — tied to CI pipeline; defer with WS5.
  - **5.1 App Sandbox** — free/on-device but high breakage risk (PTY, screenshots, automation); defer pending the cherry-picks and a dedicated risk plan.
- **Cross-Cutting CI:**
  - **CI.1 GitHub Actions matrix** — ❌ **STRIKE: external CI service.** "DEFERRED — requires user approval of paid/external service." (Local `swift test` remains mandatory and in-policy.)
  - **CI.4 `osv-scanner` / `trivy`** — ❌ **STRIKE: external scanners.** "DEFERRED — requires user approval of paid/external service." In-policy alternative: built-in `swift package audit` (free, local) — use that instead.
  - **CI.2 Integration test harness** (`ApexAgentIntegrationTests` target) — ✅ KEEP: local, free, in-scope. Depends on P0.
  - **CI.3 Snapshot testing for traces** — ✅ KEEP: local, free; depends on WS4.

---

## 3. Policy Strikes Applied (summary)

| Item | Decision | Reason |
|------|----------|--------|
| `gh issue create --repo dboone323/fleet.workspace` | 🚩 Flag + correct | Wrong repo; actual = `dboone323/ApexAgent` |
| "4 test targets" assumption | ✏️ Correct to 3 | `ApexAgentRuntime` is the app, not a test |
| WS2 WAN/cloud binding assumption | 🚩 Strike | Out-of-policy; keep LAN/localhost only |
| WS3 DI refactor | ⏸ Defer | Large, lower priority |
| WS5.2 Notarization (`notarytool` + GH Actions) | ❌ Strike | Paid Apple Dev + external CI |
| CI.1 GitHub Actions matrix | ❌ Strike | External CI service |
| CI.4 osv-scanner / trivy | ❌ Strike | External scanners (use `swift package audit`) |
| WS4 Observability | ✅ Keep | Free, on-device, additive |
| WS6 MCP Resilience | ✅ Keep | Free, on-device, additive |
| WS1 typed-handoff/registry (pure Swift) | ✅ Keep | Free, on-device, in-scope |
| WS5.5/5.6/5.7 | 🍒 Cherry-pick | Policy-aligned, on-device |

---

## 4. Execution Order (decision-ready)

1. **P0** — un-hang `ApexAgentTests` → full green gate.
2. **WS4** Observability → enables debugging of everything after.
3. **WS6** MCP Resilience → reliability.
4. **WS1** Generic Multi-Agent (pure-Swift pieces) → product value (1.6 dashboard after WS4).
5. **WS2** Server Hardening — LAN/localhost only, Wan/cloud struck.
6. **Cherry-pick** WS5.5 / 5.6 / 5.7 as standalone, policy-aligned improvements.
7. **Defer** WS3, WS5.1/5.2/5.3/5.4, CI.1, CI.4 — require explicit user approval of paid/external service before any work begins.

*No items above modify `TASK_MANIFEST.md`. Nothing has been committed.*
