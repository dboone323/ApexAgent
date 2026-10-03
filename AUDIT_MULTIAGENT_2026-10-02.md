# ApexAgent Multi-Agent Systems Audit — 2026-10-02

**Method:** Combined static re-audit (read-only file pass, no shell/grep/build on the Mac) + live test of the running Debug build from Xcode (computer control). Follow-up to `AUDIT_2026-09-28.md` and `FIXES_2026-09-24.md` — their findings are not re-reported; everything below is new or a re-verdict.
**Bottom line:** The three predicted build blockers from the Sept-28 audit are all REFUTED — the app demonstrably builds and runs. The live team check-in turn-taking WORKS (9 bots, ordered, no cross-talk). But the static pass found live confirmation-gate bypasses in delegation paths, a dead peer-approval system that silently drops delegated tasks, fake meeting consensus, and group-chat code that wipes 1:1 sessions. The live test was blocked by an unanswered computer-control approval prompt before any interaction, so approval gates, concurrency, playbooks, and delegation are untested live.

---

## LIVE TEST RESULT (2026-10-02 ~12:52–12:57 CDT)

**Confirmed working (observed, not clicked):** Team check-in turn-taking. Daniel sent "Hey @all let's do a quick team check in…" at 12:44 PM in #general (space "Apex HQ", 3 humans · 11 agents); 9 bots responded in sequence ~1 min apart (Apex → Apollo → Automator → Chief of Staff → Code Architect → Flux → Luna → Pulse → Raven), each with a "Thinking…" placeholder, a banner "✨ \<Bot\> is responding in #general…", and orange (generating) vs green (idle) status dots. No visible cross-talk or interleaving errors. Sidebar showed Oct 1 tool history: `store_memory`, `audit_projects`, `convene_meeting`, `dispatch_swarm`, `delegate_task`, `file_search`.

**Blocked:** At ~12:57 every computer.control command failed with "Approval for computer.control wasn't answered in time…" — Daniel must approve the pending prompt on his Mac/phone, then the test can resume (element catalog + plan saved at `~/workspace/apexagent-live-test-partial-log.md` on the agent VM). Session ended cleanly. `user_can_see_preview=false` (Daniel couldn't watch). Observation auth lapses after ~25s idle; `list_windows` deselects the target window (must re-`activate`).

**Untested live (blocked):** channel concurrency, slow/error agent turns, playbooks ("Pages (2)"), delegation, bot create/edit/delete, mode popup, Sync All Bots — and the approval/confirmation gate itself was never reached. DEBUG-build caveat: this build auto-approves confirmations, so gate behavior can't be validated live until a Release build.

---

## (a) FIX — prioritized

**P0 — Confirmation-gate bypasses in delegation paths (security).**
1. Nested delegation bypass survives for MLX/Ollama engines: `AgentOrchestrator.executeToolByName` (~line 1312) does its own confirm check, sets `confirmationDepth += 1`, then calls raw `tool.execute`; `Tool+Logging.swift` `executeWithLogging` (~line 64) reads `confirmationPerformed`, now a computed alias for `confirmationDepth > 0` (~lines 228–234). A sub-agent turn can therefore call `run_shell_command` with the flag still true → shell confirmation skipped. Fix: scope the flag to the outermost frame only (clear before dispatching into sub-agent turns), or thread an explicit "already confirmed by user" token instead of ambient state.
2. `executeToolByName` (Path B) bypasses ALL `executeWithLogging` safeguards: repeat-detector, `toolCallingMode == .disabled`, 20-call/turn cap, output truncation, prompt-injection sanitization, `AgentAuditLog`. Callers: `GroupChatSession.executeGroupTool` (GroupChat.swift ~362) + three NL shims below. Fix: route Path B through `executeWithLogging`.
3. Three natural-language intercept shims bypass confirmation + governance (all route through Path B): `AgentOrchestrator.sendMessage` (~1000) `directConveneMeetingArguments` fires on the prompt containing "convene_meeting" + any `[...]` — misfire: asking "What does convene_meeting [researcher] do?" convenes a real meeting; `NativeAppleEngine.streamResponse` (AgentEngine.swift ~75) duplicates it for bot sessions; `directDelegateTaskArguments` (~98) fires on prompts starting with "call/use/invoke delegate_task". Fix: require an explicit tool call from the model instead of regex intercepts, or at minimum require a confirmation before acting on a regex hit.
4. `ask_bot` and `dispatch_swarm` skip `executeWithLogging` entirely (hand-rolled `logToolStart`/`logToolEnd`) → no confirmation gate, repeat detection, disabled-mode enforcement, call cap, truncation, sanitization, or audit record. (ConveneMeetingTool and DelegateTaskTool wrap correctly — copy that pattern.)

**P1 — Silent data loss / fake results (user-visible).**
5. Attachments in bot chats are silently dropped: `BotMessageSender.sendMessage(_:attachments:)` (BotMessageSender.swift) builds the request from the parameter (default `[]`) and never drains `session.pendingAttachments`, while `BotChatView.send()` calls `session.sendMessage(text)` with no attachments — images are previewed, never sent, and `pendingAttachments` grows unboundedly. Fix: drain `pendingAttachments` in the sender (legacy `runMessageGeneration` ~940 shows the correct pattern).
6. Peer-approval system is a dead end: no SwiftUI renders a peer card or consumes `needsAttention`/`botsNeedingAttention`; `resolvePeerRequest` has no UI caller; `PeerApprovalCoordinator.expireStale()` (~120) has no caller so the "auto-denies after 15 min" comment is false and `pending` grows forever. Every `ask_bot` without a pre-existing grant is permanently blocked and the delegated task is silently dropped (text note only). Grants are keyed `(action, targetBotId)`, not per sender. Fix: either build the approval UI (badge + card surface) or remove the gate; at minimum expire stale entries and surface the block loudly.
7. `ConveneMeetingTool` quorum detection is dead: `failedTurns` filters on the `"Participant response unavailable:"` prefix (~290) but the turn loop's failure fallback (~275) produces `"Completed with no output."` — prefix never matches, `failedTurns` always empty, so a fully-failed meeting reports "Consensus reached (Confidence: 100%)". Fix: match the real fallback string.
8. `dispatch_swarm` reports a busy bot as success: `sendMessageAsync` returns nil when busy → `response ?? "Completed with no output."` → renders ✅ for a bot that never ran (DispatchSwarmTool.swift ~231). Fix: match PlaybookRunner's `runLiveTurn` "⚠️ Turn failed" marker.

**P2 — Group chat correctness.**
9. `GroupChatSession.start()` (~128–133) calls `reset()` on each participant's SHARED `BotSession` (via `botManager.session(for:)`), wiping the user's live 1:1 history views — contradicts the file's own "fresh BotSession" header comment. Fix: snapshot/clone sessions for the group.
10. GroupChat turn engine: one round only (`maxTurnsPerParticipant = 3` never read); `endTurnEarly()` (~470) double-advances when a turn is in flight (two concurrent tasks append to `messages`); `beginNextTurn()` (~167) force-unwraps `participants.first { $0.id == botId }!` (crash if a participant is deleted mid-chat); `stop()`/`cancel()` never cancel the in-flight turn task. Also: group chat has no reachable UI (ContentView never renders it; manager's weak botManager/orchestrator never assigned) — decide: wire it or remove it.
11. Meeting/debate/playbook/group-chat turns pollute 1:1 conversations: `sendMessageAsync` appends every turn to the bot's own `BotSession.messages` + SwiftData (only SpaceManager avoids it via `history: []`); ConveneMeetingTool writes its transcript via legacy `orchestrator.appendMessage`, so a bot-initiated meeting's transcript lands in the wrong chat. Fix: run collaboration turns against ephemeral or namespaced sessions.

**P3 — Concurrency races.**
12. `SpaceManager.dispatchBotTurns`: `channelGenerating[channelId]` is set with a `defer` reset but never checked → second message during an in-flight turn spawns overlapping dispatch on the same session.
13. Space turns never set `session.isGenerating` → a 1:1 `BotChatView` turn on the same bot interleaves on the shared `LanguageModelSession`.
14. Rapid sends to one bot: `SessionLifecycleManager` unregisters by sessionId, not task identity → the old turn's `defer` removes the NEW task's registration; cooperative cancellation isn't honored → zombie turn + two turns appending to one session.
15. Playbook parallel stages: Pass-2 role fallback can map multiple roles to one bot → all but one `sendMessageAsync` return nil ("⚠️ Turn failed"); result order nondeterministic → `combinedOutput` varies run to run.

**P4 — Robustness / hygiene.**
16. `BotSession.sendMessage` silently returns when busy (no feedback) — bot-to-bot/programmatic messages vanish. `BotManager.makeSession(for:)` (~64) force-unwraps weak orchestrator; `BotSession.sendMessage` falls back to a throwaway `AgentOrchestrator()` when orchestrator is nil, masking wiring failures.
17. Gateway client: chat sends are fire-and-forget (message lost if connection drops mid-send); `disconnect()` doesn't cancel the pending reconnect `Task.sleep` → a sleeping retry can reconnect after explicit disconnect.
18. `SpaceManager.inviteURL` embeds the collab token in the URL query string.
19. `SpaceManager` saves SwiftData on every streamed token (`onUpdate` → `saveContext()`) — perf hazard with concurrent turns.
20. Mention regex `@([A-Za-z0-9_\-]+)` matches emails (`foo@bar.com` → handle "bar"); bot-issued @mentions are dead (`resolveTargetBots` requires `senderKind == .human`).
21. `BotManager.createBot`/`duplicateBot` don't set `modelContext` on new sessions (persistence silently off until reload); `deleteBot` doesn't cancel an in-flight generation.
22. Dead code: `ConveneMeetingTool.createVisualSession` (~225) never called; `MultiAgentDebateCoordinator` ignores `maxRounds` and its `botManager` is never assigned in `ApexAgentApp.init` (dormant unless called); `unreadActivity`/`needsAttention` set but never rendered.

## (b) ENHANCE — gaps vs the shared-workspace vision

Daniel's stated vision: a shared workspace where humans plus a group of agents/bots multitask and collaborate together (OpenAI's bots/spaces model). Ordered by impact on that vision:

1. **Ambient approval surface.** Peer-approval cards, playbook cards, and group-chat gates are invisible unless you're looking at the exact right session (`BotManager.activePlaybookRunner` surfaces one card; `BotChatView` renders a banner only for the active session). A shared workspace needs a global pending-decisions surface: attention badges in the sidebar, a decisions inbox, and cards reachable from Spaces/legacy chat/any bot chat. Unseen cards currently hit the 300s auto-reject silently.
2. **Session scoping per collaboration context.** Space/group/playbook/debate turns today share or pollute the bot's 1:1 session (FIX #11, #13, #15). The vision needs lightweight scoped sessions: a turn runs in a context that doesn't corrupt the 1:1 history, with an explicit "promote to 1:1" or "attach transcript" action.
3. **Reachable group chat + debate UI.** The primitives exist (`GroupChatManager`, `MultiAgentDebateCoordinator`) but neither is reachable from the GUI or has its manager wired in `ContentView.onAppear`. Surfacing them — start, observe turns, intervene, end — is the core of the multitask-together vision.
4. **True channel concurrency.** Overlapping-turn protection (FIX #12), per-channel stop, and honest busy states (replace silent drops and false ✅ with "bot is busy" feedback). The live test confirmed ordered turn-taking works; concurrent channels are the untested frontier.
5. **Bot-to-bot summoning.** Bot-issued @mentions are dead (FIX #20). Agents that can call each other into a channel is a defining feature of the spaces model.
6. **Attachment parity in bot chats** (FIX #5) — a workspace where you can't show an agent an image is incomplete.
7. **Deterministic playbook execution:** stable role→bot assignment feedback and ordered parallel-stage results, so repeated runs are comparable.
8. **Human teammate presence done safely:** "Act As" and invite URLs exist, but the invite embeds the collab token in the query string (FIX #18) — move to a short-lived single-use token exchange.
9. **Workspace-level activity feed:** who's generating where, which channels are hot, pending decisions — the orange/green dots exist per bot; aggregate them.
10. **Working consensus semantics** (FIX #7): meeting outcomes need real quorum math before they can drive anything.

## (c) TRIAGE DEEPER — needs investigation before a verdict

1. **Group tool allowlist enforcement (FIX-adjacent):** `groupToolPermission`/`executeGroupTool` (GroupChat.swift ~331–368) implement an allowlist + risky-tool gate, but `runParticipantTurn` routes through `AgentRequestRouter` with the full registry and no filtering was found. UNCERTAIN — needs an Xcode content search for `executeGroupTool` / `groupToolPermission` callers to confirm whether participants can call `run_shell_command` despite the allowlist.
2. **Xcode Swift Language Version setting:** Package.swift says swift-tools-version 6.4, but the Xcode target setting governs Sendable strictness (this is why `ParallelTaskItem` holding a `@MainActor BotSession?` compiles). Read the target's SWIFT_VERSION / language mode in Xcode.
3. **Playbook URL import:** `importPlaybookFromURL` does `URLSession.shared.data(from:)` with no visible size/timeout guard at the call site, and a playbook's `descriptionText` becomes system-prompt content — trace the parse-then-import flow for prompt-injection via malicious playbooks.
4. **Server side of gateway/collab (both modified 9/30 and 10/2):** `CollaborativeServer.swift` / `ApexGatewayServer.swift` were listed but not read — auth-token check, message fan-out, and the pre-auth `.stateUpdate` broadcast need verification from the server side.
5. **Is GroupChatManager truly unreachable?** Verified ContentView doesn't render it, but a sheet or tool could wire it — needs a UI trace or content search for `startGroup`.
6. **Live verification pending** (blocked on the computer-control approval): approval gate under a Release build, attachments in bot chat, `ask_bot` without a grant, rapid double-send to one bot, starting a group chat from the GUI, channel concurrency while a turn is in flight.
7. **AgentRequestRouter filter table:** the `.archetype` sender-identity tool-stripping was confirmed in DelegateTaskTool's path, but the router's own filter table wasn't line-read — verify sub-agents can't reach `delegate_task`/`convene_meeting`/`dispatch_swarm` through the router.

## DANIEL'S LIST (needs his Mac / Xcode)

- [ ] Approve the pending computer-control prompt (Mac or phone) so the live test can resume.
- [ ] Xcode content search: `executeGroupTool` / `groupToolPermission` callers (settles TRIAGE #1).
- [ ] Check the Xcode target's Swift Language Version (settles TRIAGE #2).
- [ ] Build a Release scheme and re-verify confirmation gates (Debug auto-approves by design).
- [ ] Decide: wire group-chat/debate UI, or remove the dormant code (FIX #10, #22).
- [ ] Decide: build the peer-approval UI, or remove the gate (FIX #6).

## LIVE-TEST LOG (2026-10-02, CDT)

- 12:52:52 — `device.list`: Mac online (MacBookPro18,1). `device.describe` confirmed schemas.
- 12:52:5x — `computer.session start` ("Live-testing ApexAgent multi-agent chat") → session cc-1, but `user_can_see_preview=false`.
- 12:53 — `computer.observe` failed ("A current authorized computer session and screen access are required") — session start alone does not authorize observation.
- 12:53 — `computer.control list_windows` OK (no prompt). Found "Apex Agent" window_id 6789 (1594×1132); also open: Xcode project, Xcode Permissions, Antigravity, Outlook, Finder.
- 12:53–12:54 — `activate` window 6789 → session cc-2. `computer.observe` → full screenshot captured (only visual obtained).
- 12:54–12:56 — Observed mid-check-in: Daniel's 12:44 PM "Hey @all…" message; 9 bots responding in order ~1 min apart with "Thinking…" placeholders, "✨ \<Bot\> is responding in #general…" banner, orange/green status dots. Space "Apex HQ" (3 humans · 11 agents), channels #general/#architecture/#ship-room. Right panel: Members/Pages/Thread tabs, invite URL, HUMAN TEAMMATES (Alex Rivera "Act As", Daniel Stevens OWNER Active, Elena Vance "Act As"), AI AGENT TEAMMATES (11) + "Sync All Bots". Message field: "Message #general — tag @bot to summon an agent, @all for everyone, or @human…". Sidebar Oct 1 tool rows: `store_memory`, `audit_projects`, `convene_meeting`, `dispatch_swarm`, `delegate_task`, `file_search`.
- 12:55:25 — After ~25s idle, observe failed; a control command re-authorizes observation. `list_windows` deselects the target ("No current target window can be observed") — must re-`activate` after.
- 12:55:48 — Re-activated (cc-4), captured 120-element accessibility catalog (saved on agent VM: `~/workspace/apexagent-live-test-partial-log.md`).
- 12:57 — All `computer.control` commands began failing: "Approval for computer.control wasn't answered in time and may still be open on the user's Mac or phone." Waited 60s, retried once, same failure → stopped per protocol, ended session cleanly. **No clicks or keystrokes were ever sent** — all findings above are from observation only.

## COVERAGE & CONFIDENCE

- Fully read: SpaceManager.swift (991), GroupChat.swift, PlaybookRunner.swift (targeted), ApprovalPolicy.swift (272), BotManager.swift (targeted), AgentOrchestrator.swift (targeted multi-agent paths), ConveneMeetingTool.swift, DispatchSwarmTool.swift, AskBotTool (call sites), MultiAgentDebateCoordinator.swift (111), BotMessageSender.swift, SessionLifecycleManager.swift (126), Tool+Logging.swift (targeted).
- Sampled: AgentRegistry/AgentProfiles/AgentRequestRouter/ProviderFallbackExecutor (router filter table not line-read), ChiefOfStaff.swift, Space UI views (not read — SpaceManager was), BotChatView.swift (targeted passes), TeamPlaybook import/export (call sites only).
- Not covered: CollaborativeServer.swift / ApexGatewayServer.swift internals (modified 9/30, 10/2), full BotChatView end-to-end, Xcode project settings (SWIFT_VERSION).
- Confidence: build-blocker verdicts are high (running app is direct evidence). Static bug findings are code-reading confidence — none compiled or executed. All live claims are observation-only; interaction claims await the resumed live test.
