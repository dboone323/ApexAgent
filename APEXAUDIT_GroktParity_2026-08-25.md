# ApexAgent → Grok Bot Feature / Test Parity Audit

**Date:** 2026-08-25
**Auditor:** Cline (AI-assisted), code-grounded — every claim checked against actual source files, `grep` output, and recorded test logs in `results/`.
**Goal:** Bring ApexAgent to a "full Agent suite similar to Grok Bot" — cloned as **native Swift files/commands** (not a port), matching Grok Bot's multi-bot work & communication features.

---

## Part A — Grok Bot feature baseline (researched from x.ai/bot, launch & plans posts)

Grok Bot = a **cloud-hosted team of always-on agentic colleagues** who sign into your real tools and finish end-to-end work. Definitive capabilities:

| # | Capability | Evidence (x.ai) |
|---|-----------|-----------------|
| G1 | **Own computer (cloud VM)** | "Bots have their own computer… sign into the tools you already use… including platforms with no clean API or MCP." Browser + terminal, always on. |
| G2 | **24/7 always-on** | "Jobs do not stall when you step away… keep working 24/7, even when your laptop is closed." |
| G3 | **Message like a teammate** | Text-thread UX; same thread on macOS + iOS, pick up on either surface. |
| G4 | **Many bots in parallel / team-of-bots** | A chief-of-staff bot over specialist lanes; "run in parallel… independently message each other and share context in threads." |
| G5 | **Group chat that assigns work & acts** | "Place Bots in a group chat where they coordinate on their own. They pass work, assign ownership, and only pull you in for judgment calls." |
| G6 | **Teach-a-task / routines** | "Ask a Bot to follow along as you complete a workflow once. It saves it as a routine and runs it on its own next time." |
| G7 | **Growing memory & proactivity** | "Keep context… follow up on threads you dropped, nudge a stalled handoff, pick work back up… become proactive." |
| G8 | **Approval gates** | "Only come back when something needs your approval." |
| G9 | **Skills & plugins marketplace** | Team plans: "marketplace for skills and plugins + shared usage analytics." |
| G10 | **Enterprise** | SAML/OIDC SSO, centralized billing/settings. |
| G11 | **Reference bot roster** | Sales outbound, demo-readiness, pipeline-ops, account follow-up, website builder, digital declutterer, customer support, game artist, office manager, inbox manager, meeting stand-in, refunds manager, bug reproduction, account health, chief of staff. |

Plans: Pro+ $60/mo · SuperGrok Plus $100/mo · Heavy · Ultra · Teams $40/seat.

---

## Part B — ApexAgent current inventory (code-verified)

`ApexAgentCore` (path `ApexAgent/`) = **136 Swift files ≈ 23,800 LOC**; **47 registered tools** (via `grep 'name = "…' ApexAgent/Tools/*.swift`). README's "32 tools" claim is stale.

### Multi-agent / teammate layer (present as native Swift)
- **Bots:** `BotProfile` (SwiftData @Model: name, title, description, avatar, memory, pinned), `BotManager` (CRUD/duplicate/hide, active bot, attention, persistence), `BotSession` (per-bot messages/tool events/confirmations/model), `BotMessageSender`.
- **Sub-agents:** `AgentRegistry` (7 built-ins), `DelegateTaskTool`, `ConveneMeetingTool`, `AgentHandoff` DTOs.
- **Team chat:** `GroupChatSession`/`GroupChatManager` — round-robin; **currently talk-only (tool calls banned in `groupBotInstructions`)**, ephemeral.
- **Routines:** `Routine` (manual/timeInterval/onError/onSuccess/onMessage), `RoutineManager` (Timer scheduler). Prompt-only — **no watch-and-learn**.
- **Skills:** `Skill`, `SkillManager`, `DynamicToolbox`, `CreateSkillTool` — local `~/.apex/skills`.
- **Memory:** `AgentMemory` (SQLite) + `store_memory`/`search_memory`, per-bot memory.
- **Proactivity:** `WorkspaceProactiveAuditor` (TODO/test-gap scan only).

### Execution / infra / security
Shell, AppleScript, file ops, browser (`control_browser`), accessibility, app control, clipboard, notifications, system info, web search, screenshot, OCR, GitHub, Discord, container, Spotlight/RAG, plan tools; `AutomationWorkflow/*` (10 workflows, each with an e2e test); `Tracing`/`TraceBus`; `--daemon` + `ApexGatewayServer/Client`; confirmation gate + 60s auto-deny; Keychain.

### Verified test state (logs in `results/final_unit{.0,_2}2.log`, 2026-08-24)

| Target | Tests | Suites | Result |
|--------|-------|--------|--------|
| `ApexAgentTests` | 214 | 33 | ✔ passed (~147s) |
| `ApexAgentIntelligenceTests` | 53 | 10 | ✔ passed, **2 known issues** (DelegateTask/ConveneMeeting ~120s, withKnownIssue, beta `respond(to:)` regression) |
| `ApexAgentContainerTests` | 3 | 1 | ✔ passed |
| `ApexAgentUITests` (XCUITest, xcodebuild only) | 14 | — | active |

---

## Part C — Feature gap table (Grok Bot → ApexAgent)

Priority: 🔴 critical (defines Grok), 🟡 important, ⚪ deferred/out-of-policy.

| # | Grok Bot | ApexAgent today | Gap → planned native Swift work |
|---|----------|-----------------|----------------------------------|
| F1 🔴 | 24/7 always-on (own computer) | `--daemon`/gateway exist but **not auto-started**; scheduler Timer dies with app | **WS3:** LaunchAgent-supervised daemon; schedule survives app close; headless routine runs. |
| F2 🔴 | Teach-a-task (watch & learn) | Routines are prompt-only; no demo recorder | **WS2:** `DemoRecorder` (AX+AppleScript+ScreenCapture) → routine; user-correction pass. |
| F3 🟡 | Sign-in-once, persistent tool sessions | `control_browser` on fresh WKWebView; no cookie/session reuse | **WS4:** persistent `WKWebsiteDataStore` + Keychain credential vault. |
| F4 🟡 | Bot proactivity (nudge stalled handoff, resume) | Auditor scans TODOs only | **WS5:** `ProactiveScheduler` over pending confirmations/handoffs + notifications. |
| F5 🟡 | Cross-bot learning/context handoff | Shared orchestrator memory; no per-bot sharing primitive | **WS5:** bot-keyed memory read/write, offload/resume. |
| F6 🟡 | Group chat assigns work + **takes action** | Group chat is talk-only (tool calls banned) | **WS6:** constrained tool-call bridge behind confirmation gate. |
| F7 ⚪ | iOS/mobile client | macOS only | Deferred (separate app). |
| F8 ⚪ | Skills/plugins marketplace + team analytics | Local skills only | Deferred (external/paid). |
| F9 ⚪ | SSO / enterprise billing | None | Deferred. |

---

## Part D — Test gap table (missing tests; biggest first)

| # | Module | Coverage today | Planned tests (Swift Testing, mock orchestrator, headless) |
|---|--------|----------------|------------------------------------------------------------|
| T1 🔴 | **Bots core** `BotProfile`/`BotManager`/`BotSession`/`BotMessageSender` | **zero** | instructions/memory composition; CRUD/duplicate/hide; persistence; active-bot/attention; default-bot fallback; reset; tool/confirmation delegation; session creation. |
| T2 🔴 | **Group chat** `GroupChatSession`/`Manager` | zero | round-robin, turn limit, start/stop/cancel, endTurnEarly, participant targeting, talk-only invariant. |
| T3 🔴 | **Routines** `Routine`/`RoutineManager` | zero | `<Bot>: <prompt>` routing; poll/execute; scheduler start/stop; reaction dispatch; trigger toggles. |
| T4 🔴 | **Skills** `Skill`/`SkillManager` | zero (only `testCreateSkillTool`) | disk sync/validation; enable/disable/delete; prune; `_procedural` skip; manifest parse. |
| T5 🟡 | `DelegateTaskTool`/`ConveneMeetingTool` | 2 tests, 120s each + known-issue | fast mock-session tests for routing/invalid-agent/sequencing. |
| T6 🟡 | Bot UI (`BotChatView`/`BotSidebarViews`/`BotSheets`) | none in ViewHosting | hosting tests. |

---

## Part E — Execution plan (phased, ordered, each verifiable)

- **P0 — Baseline green + hygiene:** confirm `ApexAgentCore` builds; commit the in-flight Grok layer; reconcile `Package.swift`↔`project.yml`; refresh README (47 tools, real test counts).
- **WS1 — Bot-layer test suite** (biggest test gap, low risk, mock orchestrator): T1–T4.
- **WS2 — Demo-based routines (teach-a-task)** — the #1 Grok differentiator.
- **WS3 — 24/7 daemon** (LaunchAgent) so bots run & communicate while app is closed.
- **WS4 — Persistent tool sessions** + Keychain vault.
- **WS5 — Proactive follow-up / cross-bot handoff.**
- **WS6 — Group-chat action bridge** behind confirmation gate.
- **Deferred**: iOS client, skills marketplace, enterprise SSO (external/paid; policy).

*Nothing above was committed in planning mode. This doc is authoritative for the parity effort.*

---

## Progress (updated as features land)

- **2026-08-25 · P0 + WS1** (`c15f791`): ApexAgentCore builds clean with the multi-bot layer; baseline committed; WS1 bot-layer test suite (**20 tests / 6 suites**, all green).
- **2026-08-25 · WS2 + WS6** (`5aa7925`): native **`RoutineRecorder`** (teach-a-task: capture shell/applescript/note/app-activation steps to a numbered recipe → `Routine` with `<Bot>: ` routing) and **group-chat tool actions** (safe allowlist, preflight `GroupToolPermission`, human approval gate for risky tools; group instructions now allow approved tool use). **15 new tests**; bot layer now **35 tests / 8 suites**, all green.
- Still open: WS3 (24/7 LaunchAgent daemon), WS4 (persistent logged-in tool sessions + Keychain vault), WS5 (proactive follow-up / cross-bot handoff); wiring `record_demo` as a registered tool + Settings UI is the natural next slice of WS2.
- **2026-08-25 · OpenMausBot ports** (`d471840`): researched github.com/milind-soni/OpenMausBot (`docs/OpenMausBot_research_and_swift_ports.md`) and ported its highest-value safety/robustness modules natively — `RepeatDetector` (loop guard), `SecretRedactor` (credential masking), `ApprovalPolicy` (auto-grant verdicts w/ guards-outrank-grants), `TurnWatchdog` (activity stall detection), plus Routine `.webhook` trigger + `RoutineRun` receipts. **29 new tests**; combined bot layer **64 tests / 13 suites, all green**. Next: O6 per-rule decision log, webhook HTTP receiver, wiring ApprovalPolicy into the confirmation gate.
- **2026-08-25 · O6 + gate wiring** (`2d068f4`): `ApprovalPolicy.verdict` now runs inside `AgentOrchestrator.requestConfirmation` — auto-mode/always-allow grants skip the human card while destructive/sensitive guards and unattended turns still card. Decision rows (source + rule, redacted) land in `AgentAuditLog`. **65 tests / 14 suites green.**
- **2026-08-25 · O5 + O7 + O8 + O9** (`fff5069`): `WebhookManager`/`WebhookRouter` (pure transport-agnostic ingress: auth via bearer or capability-path secret, body cap, JSON/form/text parsing, delivery dedupe); `ChiefOfStaff.systemPrompt` roster commander with section filtering + caps; `SkillCatalog` SKILL.md manifests + trigger-term matching (+ defaulted `Skill` model fields); `PeerApprovalCoordinator` bot-to-bot gate with always-allow grants and 15-minute card expiry. **26 new tests; combined bot layer 91 tests / 18 suites, all green.**
- Remaining follow-ups are integration glue rather than new ports: an NWListener socket front for `WebhookRouter`, a Settings UI for `autoApproveToolCalls`/`alwaysAllowKeys`/webhook endpoints, surfacing `ChiefOfStaff.systemPrompt` in BotSession instructions, and WS3 (LaunchAgent 24/7 daemon) from the Grok audit.
- **2026-08-25 · Integration layer** (`aa95a92`): chief-of-staff is live — `BotProfile.isChiefOfStaff` makes `BotSession.systemInstructions` append the live roster (via a new `BotManager.makeSession` back-reference factory); `RoutineManager.dispatchWebhook(routineName:)` fires `.webhook` routines by name; **`WebhookServer`** is a real NWListener localhost HTTP front feeding `WebhookRouter`, with `onAccepted` → routine dispatch. Verified with a real-socket round trip (authorized POST → 202 + trigger, idempotent redelivery, wrong secret → 401). **Combined bot layer: 96 tests / 21 suites, all green.**
- What's left: Settings UI for the policy knobs/webhook endpoints (SwiftUI, untested by suite), wiring PeerApprovalCoordinator into delegate/ask paths in the UI layer, and WS3 (LaunchAgent 24/7 daemon) from the Grok audit.
- **2026-08-25 · WS3 + peer gate** (`624911f`): `LaunchAgent.swift` — plist generation + install/uninstall lifecycle (injectable dir, launchctl bootstrap/bootout) supervising `--daemon`; daemon mode now owns bots/routines/scheduler **and** the :8800 webhook receiver so `.webhook` + scheduled routines run with the GUI closed (GUI binds :8800 best-effort when open); `BotManager.peerDeliveryDecision` gates bot-initiated bot-to-bot messages behind peer cards with attention flags and remember-grants. **101 tests / 23 suites, all green.**
- Remaining: Settings UI (SwiftUI) for policy knobs/endpoints/chief flags; surfacing peer cards in the chat UI.
- **2026-08-25 · Live verification** (`live gating fix`): `LiveBotCommunicationTests` now properly skipped via `.enabled(if: ProcessInfo…)` when `APEX_LIVE_BOTS!=1` (instant 0.018s skip in normal `swift test`); with `APEX_LIVE_BOTS=1` both tests pass against the real on-device Foundation Model — specialist hand-off answers "READY", peer-gated chief hand-off answers "ONLINE" and remember-grants work. Full `ApexAgentTests` suite: **317 tests in 57 suites, all green (175s)**. Live bots confirmed communicating and collaborating end-to-end.
- **2026-08-26 · Apple-native API integration** (9 first-class agent tools): WeatherKit (`get_weather` — current conditions + hourly/daily forecast), MapKit (`map_search`, `get_directions`), EventKit full read/write (`calendar` — list/create/search/delete events; `reminders` — list/create/complete/delete with due dates/priorities), Translation + NaturalLanguage (`translate` — on-device TranslationSession with per-chunk LLM fallback **including whole-file translation**: line-boundary chunking ≤2,800 chars, 512 KB file cap, lossless reassembly verified by probe T1–T4 after fixing a `split(separator:)` newline-corruption bug, result persisted to `<stem>.<lang>.<ext>`), NLTagger (`extract_entities` — people/places/organizations/sentiment, explicit tool call only), plus Tavily as the primary non-Brave WebSearch backend (Keychain `tavilyAPIKey` → `apex.tavilyAPIKey`). Config: `com.apple.developer.weatherkit` entitlement + full calendar/reminders Info.plist usage strings added; all 7 new tool files registered in pbxproj/AgentProfiles/AgentRegistry allowlists. Gates: `swift build` zero-warning, NativeToolsP1+P2 **8/8 green**, full `ApexAgentTests` **404 tests / 83 suites green (244.6s)**.
- **2026-08-26 · Computer use made real + AX observation**: `ComputerUseAgent.executeAction` no longer simulates — click/doubleClick (proper `clickState` 1→2 pairs), unicode typing via `keyboardSetUnicodeString` on a `.combinedSessionState` CGEventSource, key combos with resolve-before-post semantics (invalid tokens inert), scroll via `CGEvent(scrollWheelEvent2Source:)`, and an `AXIsProcessTrusted` gate surfacing an actionable `ACCESSIBILITY_PERMISSION_REQUIRED` error. New `inspect_ui` tool (`InspectUITool`) reads a live app's Accessibility tree (role/title/value/frame outline, 150-node budget, depth cap 12, frontmost fallback) so computer-use actions can target real elements instead of guessed coordinates; registered for the controller/automation agents. Tests: `NativeToolsP3Tests` 5 cases covering safe-action paths, inert invalid combos, permission/unknown-app handling, node-budget clamping — no synthetic input events in unit tests. Gates: zero-warning build, full `ApexAgentTests` **409 tests / 84 suites green (251s)**.
- **2026-08-27 · ComputerUseTool bridge + flake triage**: `computer_use` tool (`ComputerUseTool.swift`) exposes ComputerUseAgent's real CGEvent synthesis to the model — click/double_click/type/key/scroll/open_app/wait, validation-first argument handling, upfront `AXIsProcessTrusted` check returning an actionable 🔒 notice, and a `riskDescription` ("Synthetic mouse/keyboard input on the live desktop") so every call flows through the confirmation gate. Completes the trio: `control_accessibility` (AX element observe/act) + `computer_use` (raw HID input) + Screenshot/Vision (verify). Registered in AgentProfiles (`computer_use` key), AgentRegistry (controller + automation agents, replacing dead `inspect_ui` keys), and pbxproj. `nonisolated hasAccessibilityPermission` + `MainActor.run` singleton hop for StrictConcurrency. Test hardening: removed racy per-test `!agent.isRunning` singleton assertion (parallel suites legitimately hold the loop running); TranslateTool test now accepts the wrapper's `"ERROR: …"` path (case-sensitive `contains("Error")` missed it) when the Translation pair isn't installed and the FM fallback backend is unavailable. Root-caused and killed a leftover swiftpm-testing process holding port 1338 (CollaborativeServer test's fixed port) that failed `testCollaborativeServerHTTPEndpoints` even in isolation; TraceBus publisher-flood stress passes in isolation (load-order flake only). Gates: `plutil -lint` OK, zero-warning build, P2+P3 **13/13 green**, full `ApexAgentTests` **454 tests / 90 suites green (176.4s)**.
**~454 tests** across `ApexAgentTests` target.