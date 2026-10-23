# ApexAgent: Spaces on the Tart VM — Unified Design

**Date:** 2026-10-23 · **Status:** Researched, not yet built · **Supersedes the driver model of:** `apexagent-sandbox-design.md` (2026-10-21) — that document's safety model is inherited wholesale; what changes is *who drives the VM and when work lands*.
**Research basis:** sourced web report on Tart capabilities, execution channels, and no-paid-account signing (2026-10-23), plus a read of the current codebase.

## Decisions (Daniel, 2026-10-23) — these supersede any conflicting section below

1. **VM per Space** — as recommended in the body below: one Tart clone of `apex-base` per Space (`apex-space-<spaceID>`), at most 2 running at once. (Daniel first chose a single shared VM to avoid overloading the 16 GB host, then reversed that call the same morning and adopted the recommendation.)
2. **Opt-in per Space** and **host bots drive via `tart exec`** — as recommended below.
3. **Gate strictness** as recommended: in-VM gate + host pristine re-run for ApexAgent-repo Spaces.
4. **Cline is the implementation agent** for this work (Monarch supervises). For this work, Daniel authorises Cline to **commit and merge when the full gate is green** (clean build + unit plan + SwiftSyntaxLintGate) — this replaces the "merges are Daniel's clicks" rule *for this implementation only*, and every commit/merge must be reported.
5. Phase 0 is largely pre-verified: the `~/ApexSandbox` harness already drives clones of this same base image with `tart exec` in production runs (Oct 21–22), and the in-guest toolchain matches the host exactly (Xcode 27.2 / 27B48, Swift 6.4.2 — SETUP_REPORT.md). Remaining probes are confirmatory only.

## The goal, in one paragraph

ApexAgent today is two systems that happen to share a repo: (1) the app — multi-bot, Spaces, playbooks, the confirmation/risk layer — whose tools execute **on the host, directly against Daniel's real files**; and (2) the `~/ApexSandbox` harness — shell scripts that clone a Tart VM, hand the repo to an in-guest agent (`agy`), and bring fixes out as a git bundle. This design merges them: **the automated loop stops being a separate harness. Instead, a Space can be bound to a VM workspace.** The Space's own bots — the same bots, playbooks, approvals, and risk gates as today — do their file, shell, and git work *inside a per-Space Tart clone*. Nothing reaches the host repo until the Space's work passes the full gate (build, tests, lint, pre-push constraints, test-integrity check) inside the VM, and even then it lands only as a reviewable bundle on a quarantine branch. Daniel reviews and merges by hand, exactly as now.

## What does not change

- **Part 1 stays intact.** SpaceManager, CollaborativeServer, PlaybookRunner, BotManager, the tool census, `ToolDispatchEngine.shouldConfirmTool` and the risk map all keep working as they do today. Confirmation policy sits *above* execution, so moving execution into a VM does not touch it.
- **The sandbox safety model stays intact.** Pristine `apex-base` image (never worked in), no host credentials or Keychain in the guest, Softnet networking with the allowlist egress proxy (`~/ApexSandbox/proxy.py` + `allowlist.txt`), hard caps, one-command kill. The real repo is **never** mounted into the guest read-write — it enters as a git bundle, and results leave as a git bundle.
- **Daniel's rules stay intact.** No auto-merge, ever. Commits/merges toward the real repo are Daniel's hands.

## Why this works without a paid Apple Developer account (researched)

- ApexAgent shells out to the `tart` CLI as a subprocess (`Foundation.Process`). Spawning a subprocess needs **no entitlement at all**; the virtualization privileges live in Tart's own signed `tart.app` (it ships an embedded provisioning profile for exactly this). **Invoke the real binary at `tart.app/Contents/MacOS/tart`, not a shim**, so Tart picks up its own profile.
- The app's requirements are therefore just: **ad-hoc signed, App Sandbox OFF, Hardened Runtime OFF** — which is already how the local build runs (the F8 entitlement split already keeps `app-sandbox=false`). Gatekeeper does not block locally built apps (no quarantine attribute), and **notarization is irrelevant** — it only matters for distribution, which never happens here.
- Fallback exists but is not recommended: driving Virtualization.framework directly also works ad-hoc — `com.apple.security.virtualization` can be self-asserted with `codesign --sign -` for local use (Apple's own containerization repo does this) — but then we would have to rebuild everything Tart gives us for free: OCI images, APFS clone lifecycle, and the guest agent behind `tart exec`.
- Tart's licence (Fair Source 0.9) is royalty-free on personal computers and expressly exempts devices used by a single individual from its 100-core use limitation. Non-issue for this use.

## Architecture

```
HOST — ApexAgent app (ad-hoc signed, sandbox OFF)
─────────────────────────────────────────────────────────────
 SpaceManager ── Space.executionTarget = .host | .tartVM
      │
      ├─ ToolDispatchEngine (confirmations + risk map — unchanged)
      │        │
      │        ▼  filesystem / shell / git tool family only
      │   ExecutionBackend (protocol on AgentOrchestrator)
      │     ├─ HostBackend        → today's behaviour
      │     ├─ AppleContainer     → existing apex.appleContainersEnabled path
      │     └─ TartVMBackend      → TartCLIClient ──Process──► tart.app/Contents/MacOS/tart
      │                                                        exec / clone / run / stop / delete
      └─ VMWorkspaceManager (new, Models/ — sibling of ContainerManager)
            owns per-Space VM lifecycle, gate runs, bundle export, landing
      │
      └─ Landing area: ~/ApexSandbox/review-clone (existing pattern)
            quarantine branches: space/<space-name>-review

GUEST — Tart VM `apex-space-<spaceID>` (clone of apex-base, per Space)
─────────────────────────────────────────────────────────────
  ~/ApexAgent checkout (seeded from host git bundle)
  Tart Guest Agent (for tart exec) · auto-login ON · no host credentials
  Network: Softnet + allowlist proxy only
```

### The seam already exists

The tools are built centrally in `ToolDispatchEngine.buildAllTools`, every tool receives the shared orchestrator, and `ShellTool` **already branches on execution mode** — it checks `apex.appleContainersEnabled` and skips host path-safety checks when running in the isolated container. This design generalises that one-off flag into an `ExecutionEnvironment` resolved per Space from the orchestrator (`.host` / `.appleContainer` / `.tartVM(spaceID)`), and routes only the tools that touch a workspace:

- **Routed into the VM:** `run_shell_command`, the file family (read/write/patch/delete/move/list/create-directory/search), and `git_operation`.
- **Stay on the host:** everything else — web, memory, calendar, notifications, and the screen/accessibility tools (a headless guest has no meaningful host screen; VM Spaces are for code work, and that scoping is a feature).
- MCP tools keep the Round-3 fail-closed treatment; a dynamically discovered tool is never silently routed anywhere.

From the bots' point of view nothing changes: same tool names, same arguments. File paths are repo-relative and map to the guest checkout. One mechanical detail from the research: `tart exec` runs as the guest's logged-in user in its **default working directory** (caller-supplied user/cwd are ignored), so the backend prefixes every command with `cd <guest checkout> &&`, and `apex-base` must have auto-login enabled or the guest agent has no session to answer.

### VM per Space (not per run, not shared)

The old harness cloned per *run* because its runs were one-shot tasks. Spaces are long-lived collaborations, so the clone is per *Space*: provisioned when the Space starts, kept while the Space lives (bots keep their checkout and build caches between turns), suspended or stopped when idle, deleted when the Space is archived — after a final landing decision. APFS copy-on-write makes clones near-instant and near-free until the guest diverges, so this costs little. Two hard limits shape scheduling:

- **At most 2 macOS VMs may run at once** on one host (Apple SLA / Virtualization.framework) — so at most 2 VM-bound Spaces are *running* simultaneously; others wait or stay stopped until started.
- On Daniel's 16 GB M1 Pro, one build-active guest (~10 GB, 6–8 CPU, per the existing sandbox sizing) plus the host is the realistic working point. A second running VM is for light work only.

### Execution channel: `tart exec` primary, SSH fallback

Researched comparison, condensed: `tart exec` (shipped with the Tart Guest Agent, announced 2025-06-01; preinstalled in all non-vanilla Cirrus images) streams I/O over a Virtualization.framework channel — **no SSH, no guest networking** — and exits with *exactly* the guest command's exit code, which is what a test gate needs. It is immune to the guest's network state and avoids the macOS 15 "Local Network" permission pop-up that the host app would trigger by SSHing into the guest. SSH via `tart ip` stays as the debugging/bulk-transfer fallback. Raw virtio-vsock is **not** available under Tart (the socket device belongs to the `tart run` process; Tart exposes no proxy), and a custom in-guest daemon is unjustified for v1.

File transfer: there is no confirmed `tart cp` in the documented versions, so transfers use the two inert channels — **git bundle in** (host → guest, at provisioning and on re-seed) and **git bundle out** (guest → host, via a single-purpose outbox directory mount — `~/ApexSandbox/exports`, never the repo — or `scp` over the SSH fallback). The host treats everything arriving in the outbox as untrusted data: `git bundle verify` before any fetch, and bundle import runs no guest code on the host.

## The gate — how work lands ("pre-push", enforced by the host)

A Space's work lands only through this sequence. Enforcement lives in `VMWorkspaceManager` on the host, never in guest-side hooks (the guest is agent-writable, so its hooks are advisory at most — the repo's own hooks still run in-guest on commit via the existing `GitHookGate` model, but the landing decision never trusts them):

1. **Commit in guest.** Bots commit their work in the guest checkout (in-guest commits are cheap and disposable).
2. **In-VM gate**, run by the host via `tart exec` against the committed HEAD: clean build → full unit plan with `-resultBundlePath` (exact totals, xcresulttool-parsed — the fix-loop standard) → SwiftSyntaxLintGate → warning budget (currently 4, the documented macro artifact). Any red = the landing stops, results stream back into the Space's chat as evidence.
3. **Test-integrity check (host-side).** The exported diff's file list is checked against the protected set — test targets, test plans, CI config, gate/hook configuration (the lists `TestPlanIntegrityAuditor` already maintains). Any touch = automatic reject, unless the Space's task was explicitly a test task and Daniel overrides. This is the reward-hacking control from the sandbox design, kept verbatim: agents weakening tests to go green is documented behaviour, so the check is not optional.
4. **Quarantine.** Host runs `git bundle verify`, fetches into `space/<name>-review` in the review clone, and — for Spaces working on the ApexAgent repo itself — re-runs the pristine host test suite there before presenting anything (the old design's step 5; the guest's green run is evidence, the host's pristine run is proof).
5. **Daniel reviews and merges manually.** Unchanged. The VM is kept until he decides, then deleted either way.

## What happens to the two parts

- **Part 1 (the app)** gains: `TartCLIClient`, `VMWorkspaceManager`, the `ExecutionBackend` routing, a Space-level "Run in sandbox VM" setting, gate/landing UI in the Space view, and VM status surfacing (extending the existing ContainerManager/ContainerStatusTool patterns).
- **Part 2 (the harness)** retires *as a driver*: `run.sh` / `watcher.py` / `task-prompt.txt` and the in-guest `agy` loop are no longer how work gets done — the Space's own bots drive, through `tart exec`. Its assets move in, not out: `apex-base` (with the guest agent verified present, auto-login on, default password changed), `proxy.py` + `allowlist.txt` (supervised by the app or left as the host service the app starts alongside `tart run`), and the `exports/` + `review-clone/` landing pattern.

## Phasing

- **Phase 0 — probes (no new code).** On Daniel's Mac: `tart --version`; `tart exec --help` present; boot `apex-base`, run one `tart exec` smoke command (proves guest agent + auto-login); `xcodebuild -version` in-guest vs the project's macOS 27 / Swift 6.4 requirement (the known #1 setup risk from the sandbox design — stop if mismatched).
- **Phase 1 — lifecycle.** `TartCLIClient` + `VMWorkspaceManager`: clone/set/run/stop/delete + status, driven from a debug surface. No tool routing yet.
- **Phase 2 — routing.** `ExecutionEnvironment` on the orchestrator; shell/file/git families routed for VM-bound Spaces; one test Space works end-to-end on a scratch repo.
- **Phase 3 — gate + landing.** The five-step landing sequence above, with results posted into the Space chat and the quarantine branch presented for Daniel's review.
- **Phase 4 — retire the harness.** Archive the `~/ApexSandbox` scripts, move proxy supervision into the app, update TASK_MANIFEST / PROJECT / SECURITY docs.

## Decisions for Daniel

1. **VM per Space** (recommended — isolation, cheap CoW clones, clean test-integrity story) vs one shared VM with per-Space checkouts (weaker isolation; Spaces can see each other's half-finished work).
2. **Opt-in per Space** — a "Run in sandbox VM" toggle at Space setup (recommended) vs VM-by-default for all code Spaces.
3. **Host bots drive via `tart exec`** (recommended — this is what retires the separate loop and keeps Part 1's bots, playbooks, and approvals in charge) vs keeping an in-guest agent (`agy`) as an option inside VM Spaces.
4. **Gate strictness:** in-VM gate + host pristine re-run for ApexAgent-repo Spaces (recommended), in-VM gate only for scratch/other projects.

## Known unknowns (from the research — verify in Phase 0)

- The exact Tart release that introduced `tart exec` could not be confirmed from sources (announced 2025-06-01); the design therefore probes for it at runtime instead of assuming a version.
- Whether the installed Tart has `tart cp` is unconfirmed — the design does not depend on it.
- Research sources were vendor/primary pages fetched in full (tart.run quick start + FAQ, git-scm, Docker Sandboxes docs, Tart licensing) plus credible third-party integrations; nothing here rests on a single secondary source except the Tart 2.38.0 release note, which the design does not depend on.
