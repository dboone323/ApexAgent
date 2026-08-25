# OpenMausBot — Research & Swift Port Candidates

> **Source:** github.com/milind-soni/OpenMausBot (Apache-2.0), cloned to `/tmp/OpenMausBot-research`.
> **Purpose:** study a working open-source "Grok Bot" so we can port the ideas ApexAgent is missing, as **native Swift files/commands** (independent reimplementation of the *design*, not copied code).
> **Read with:** `APEXAUDIT_GroktParity_2026-08-25.md` (the measurement of ApexAgent vs Grok Bot).

---

## 1. How OpenMausBot works (architecture)

Electron + React chat app (Telegram-style) over a **local harness server** on `127.0.0.1` that owns every agent process. Data lives in `~/.openmausbot`. Each sidebar bot is a real agent process (Claude/Codex/Grok/… CLI or API) with its own personality, model, "computer", and connected apps.

| Layer | Files | What it does |
|---|---|---|
| **Driver SPI** | `server/contracts.ts`, `server/drivers/*` | Pluggable model providers (claude, codex, grok, pi, minimax, native, boxagent). `ProviderDriver.create() → ProviderInstance{adapter, models, generateText}`; new engine = 1 file + 1 registration. |
| **Harness** | `server/harness/bus.ts`, `registry.ts` | Spawn/supervise CLI subprocesses; normalize provider events down to ~12 canonical `RuntimeEvent` types (turn.*, item.*, request.*). |
| **Computer** | `local-computer`, `remote-computer`, `container-computer`, `vps-computer`, `box.ts`, `computer-control`, `computer-proxy` | Swappable "computer": local, containerized, cloud Linux VM (Box), VPS — proxied control + observation. |
| **Approvals** | `auto-approve`, `permission-proxy`, `peer-approval`, `decision-log` | Auto-mode + "always allow" grants (narrowed per-command for shells) + destructive/sensitive guards + unattended-block + bot-to-bot approval + a why-by-which-rule NDJSON decision log. |
| **Routines** | `routines.ts`, `webhooks.ts`, `webhook-ingress.ts` | Scheduled (once / daily+weekdays) + webhook-triggered runs with a run-state machine and receipts. |
| **Rooms (group chat)** | `member-turn`, `room-turn-timeout`, `turn-watchdog`, `steer-queue` | Round-robin turns with an activity-based stall watchdog, timeouts, and a steering queue. |
| **Team work** | `chief-of-staff`, `delegations`, `peer-approval` | A commander bot delegating to specialists + bot-to-bot approval handoffs. |
| **Skills** | `skills.ts`, `skill-library.ts`, `installed-playbooks.ts` | SKILL.md-style catalog: manifests with `triggerTerms` + `requiredCapabilities`. |
| **Memory / safety** | `message-db`, `atomic`, `redact.ts`, `repeat-detector.ts`, `branching.ts` | Thread store, atomic JSONL, credential redaction, loop detector, transcript branching. |

---

## 2. What ApexAgent already has (from the 2026-08-25 audit)

Bots (BotProfile/BotManager/BotSession/BotMessageSender), sub-agent registry + delegation/meeting + handoff DTOs, group chat (round-robin), routines (manual/timeInterval/onError/onSuccess/onMessage), skills (`.json`+shell), embedding memory, MCP client, container manager, confirmation gate + 60s auto-deny, `ToolPolicy` allowlist, `AgentAuditLog` (JSONL), `KeychainManager`, daemon + gateway, Spotlight RAG.

---

## 3. Port candidates — priority, Swift-native, Foundation-only

| # | Port | Origin | Status in Apex | Value | Implemented |
|---|------|--------|----------------|-------|-------------|
| O1 | **`RepeatDetector`** (loop guard) | `repeat-detector.ts` | none (ReflectionManager ≠ loop detection) | 🔴 bots spin on the same call = wasted tokens/actions | ✅ |
| O2 | **`SecretRedactor`** (credential redaction) | `redact.ts` | partial (Keychain; no content redactor) | 🔴 secrets leak into transcripts/audit | ✅ |
| O3 | **`ApprovalPolicy`** (auto-grant verdicts) | `auto-approve.ts` | `ToolPolicy` allowlist only; no auto-mode/always-allow/unattended-block | 🔴 Grok-style "approve what matters, unattended is guarded" | ✅ |
| O4 | **`TurnWatchdog`** (activity-based stall) | `turn-watchdog.ts` | none (no generation watchdog) | 🟡 stuck bot leaves composer locked forever | ✅ |
| O5 | **Routine webhook trigger + run receipts** | `routines.ts`, `webhook-ingress.ts` | `RoutineTrigger` lacks webhook + run status | 🟡 "Routines on a schedule" external-trigger parity | ✅ |
| O6 | Per-rule **decision log** rows | `decision-log.ts` | `AgentAuditLog` lacks rule attribution | 🟡 | ✅ |
| O7 | **Chief-of-staff / delegations** auto-commander | `chief-of-staff.ts`, `delegations.ts` | has delegation tools; no auto commander | 🟡 | ✅ |
| O8 | **Skills triggerTerms/capabilities manifest** | `skill-library.ts` | `Skill` lacks trigger terms | 🟢 | ✅ |
| O9 | **Peer-approval** gate | `peer-approval.ts` | partial | 🟢 | ✅ |

All O1–O5 are **pure Foundation** (no new dependency), trivially unit-testable.

---

## 4. Design notes for the implemented ports

- **`RepeatDetector`** — call signature = `tool + whitespace-normalized args` (a bare tool name is not a repeat). Per-thread, LRU-bounded key set (default 256), configured thresholds; `settle(thread)` resets for a new turn. Pure.
- **`SecretRedactor`** — NSRegularExpression-based, two categories: content-shaped secrets (sk-/, ghp_/github_pat_, Slack xox-, AWS AKIA, Google AIza, npm_, JWT eyJ…, `Bearer …`, PEM private keys, `name=value`/`name: value`) and env/`{name,value}`-shaped credential keys. Masks keep **shape + length**, drop the value.
- **`ApprovalPolicy`** — a pure `verdict(tool:summary:alwaysAllow:autoApprove:unattended:localScope:)` returning a named `ApprovalVerdict` (`destructive-guard` / `sensitive-guard` / `always-allow` / `auto-mode` / `unattended-block` / `local-computer-block` / `no-grant`). Shell tools are granted per-**program** (`shell:git`), never bare. Guards outrank grants (an always-allow can never widen into `rm -rf`).
- **`TurnWatchdog`** — watches **activity**, not duration (a turn can run an hour while events flow; a turn with no events for `stallMs` is wedged). Exempts turns parked on a human approval. Injected `now()` + exposed `sweep()` for tests.
- **Routines** — `RoutineTrigger` gains `.webhook`; `RoutineRun` adds a status receipts model (`queued/running/completed/failed/cancelled`).

Implementations live in `ApexAgent/*` with tests in `ApexAgentTests/*`. See git log for commits.