# ApexAgent Autonomous Sandbox — Design & Safety

**Date:** 2026-10-21 · **Status:** Researched, not yet built · **Setup prompt:** `antigravity-apexagent-sandbox-prompt.md` (companion file)

## The goal

Let an agent work on ApexAgent's codebase autonomously — build, test, fix, iterate — inside a disposable environment, so that:

- If it breaks things, Daniel's real repo at `/Users/danielstevens/Developer/ApexAgent` is untouched.
- If it fixes things, the fixes come out as a reviewable git bundle — never an auto-merge.
- Nothing leaks: no host files, no real credentials, no open network.

## Verdict on Docker (researched, with sources)

**Docker cannot do this job, in any configuration.** Daniel's two points are both true and both stop one step short:

1. **"Docker uses macOS Virtualization"** — true, but Docker Desktop uses Apple's Virtualization.framework to host *its own Linux VM*. The setting in Daniel's screenshot says so itself: "creating and managing Docker Desktop **Linux VM**." Every container is a Linux process, under every engine option (Virtualization.framework, the new Docker VMM beta, Rosetta x86 translation — all Linux guests).
2. **"Swift works on Linux/Windows now"** — true for the Swift language and toolchain. The blocker is the frameworks: Xcode, the macOS SDK, SwiftUI, and SwiftData exist only on macOS. There is no SwiftData in the Linux Swift toolchain, so no Linux environment can even compile ApexAgent — a sandbox that can't build can't verify its own fixes, which defeats the entire design.

The workarounds don't survive contact either: Apple's `container` CLI (WWDC25) is Linux-containers-only; Docker's `sbx` Sandboxes product runs AI agents in disposable **Linux** microVMs (great safety design, wrong guest OS); dockur/macos / OSX-KVM need Linux KVM, which Docker Desktop explicitly does not expose to containers, and Virtualization.framework does not support nested macOS guests at all.

**A macOS app needs a macOS guest. That's a VM, not a container.**

## Recommended architecture: Tart macOS VM

Tart (Cirrus Labs) runs real macOS guests on Apple Silicon via Virtualization.framework at near-native speed. It's the industry-standard tool (powers Cirrus Runners / GitHub macOS CI), and an open-source tool called ClodPod already ships exactly this pattern — an AI coding agent inside a Tart VM on an Xcode image.

```
HOST (Daniel's Mac)                                   GUEST (Tart VM)
───────────────────                                   ────────────────
Real repo (never mounted, never touched)
~/ApexSandbox/
  base image: apex-base (pristine, never worked in) → clone → apex-work (per-run, destroyed after)
  logs/        ← streamed harness logs (tart exec)      In-guest: repo clone (from git bundle)
  exports/     ← git bundle of fixes comes out here    In-guest: agy agent + build/test loop
  review-clone/← host re-verifies with pristine tests  Network: Softnet, allowlist egress only
Kill switch: tart stop apex-work                      Credentials: NONE baked in
```

### How a run works

1. Harness clones `apex-base` → `apex-work` (fast, APFS-backed).
2. Host creates a **git bundle** of the repo at a chosen commit and pushes it into the guest over SSH/`tart exec`. No shared folders, ever — Tart only shares host directories via an explicit `--dir` flag, which this design never passes.
3. In the guest, the agent (`agy`, Antigravity's CLI, headless mode) runs a build → test → fix loop against a task list Daniel supplies, **committing in-guest after every green run**.
4. Harness enforces caps from outside the agent: max wall-clock (default 2h), max iterations (default 25), token budget read from `agy`'s stream-json usage events. Kill switch is one command: `tart stop apex-work`.
5. Results leave as a **git bundle**. Host verifies it, fetches it into a `sandbox-review` branch in a separate review clone, and **re-runs the host's pristine test suite** against it.
6. Daniel reviews the diff. Only then — manually — do fixes move toward the real repo. The VM is deleted either way.

## Safety model (2025–2026 consensus, applied)

| Threat | Control |
|---|---|
| Agent reads/exfiltrates host data | No `--dir` shares; repo enters as a one-commit git bundle; guest has no host credentials, no SSH keys, no Keychain |
| Agent phones home / leaks code | Egress deny-by-default: Tart `--net-softnet` (guest cannot reach the host at all in this mode) + `--net-softnet-allow` CIDR restrictions + domain allowlist proxy (model API + package registries only). Perplexity's sandbox research found network policy is the leaky layer (agents bypassed egress rules in 11/54 partial-network runs; 0/108 VM escapes) — so the allowlist gets **tested with deliberate escape attempts before the first real run** |
| Real API keys stolen | Keys never enter the image. Preferred: host-side proxy injects credentials per request (the pattern Anthropic and Docker `sbx` both use). Fallback: Daniel types keys into the guest at run start; they're wiped with the VM |
| Agent goes rogue / loops forever | Hard caps enforced by the host harness, not requested from the model: wall-clock, iterations, token budget. One-command kill. Ephemeral VM per run — no persistence across runs (no cron jobs or profile hacks survive) |
| **Reward hacking** — agent weakens/deletes tests to go green (documented behavior; Anthropic caught its own agents doing this in Oct 2026) | Tests are read-only to the agent by instruction **and** by enforcement: any exported diff touching test files, test plans, the lint gate, or CI config is an automatic reject. Final judgment uses the host's pristine test copy, not the guest's |
| Prompt injection from repo content (OWASP's #1 LLM risk — ApexAgent's own docs/comments are agent-ingested content) | Repo content is data, never instructions; the only instructions come from the harness task prompt. Blast radius of a successful injection is capped at "a wasted run in a disposable VM" by all the controls above |
| Agent tampers with its own logs | Logs stream to the host in real time (`tart exec` output + `agy` stream-json). A log the agent can reach is a log the agent can edit — so it can't reach them |
| Licensing | Apple SLA §2B(iii) allows up to 2 macOS VM instances on Apple hardware for dev/test; Virtualization.framework enforces it. Plan: exactly one sandbox VM running at a time |

## Known gates and limits

- **Xcode version match is the #1 setup risk.** ApexAgent targets macOS 27 / Swift 6.4 (Xcode 27 beta toolchain). Cirrus's prebuilt `macos-*-xcode` images may carry an older Xcode. The setup prompt makes Antigravity verify `xcodebuild -version` and `swift --version` inside the guest against the project's requirements and **stop** if they don't match — fallback is installing the matching Xcode into the base VM from an installer Daniel provides.
- **RAM split:** Daniel's M1 Pro (16 GB) → guest gets ~10 GB, CPU capped at 6–8 cores. Xcode builds in-guest run near host speed; the host stays usable but not snappy during runs.
- **Default guest password:** Cirrus images ship an `admin` user with Remote Login on and a widely documented default password. It gets changed during base-image setup, by Daniel, before the pristine clone is taken.
- **Antigravity on the host stays in a review preset.** Its Turbo mode is unrestricted full-machine access — acceptable only *inside* the disposable guest, where the VM boundary is the containment. The host-side setup runs in Request Review (every command approved).

## First task list for the agent (small, verified items)

1. ApexCLIRouter hardening: call `loadRoutines()` before reading the routines cache (~lines 601, 611, 779).
2. SwiftSyntaxLintGate: skip cleanly when there are no changed Swift files.
3. Remove the redundant `Sendable` conformance at `SpacePageProposal.swift:30`.
4. Investigate File → New Conversation and the Compose toolbar button (no visible effect in beta test) — fix or remove, with evidence.

Feature work (Playbook run UI, approval-card surface) comes later, once the loop is proven on small fixes.

## Sources (key)

- Apple `container` CLI (Linux-only): https://github.com/apple/container
- Docker Sandboxes (`sbx`, Linux microVMs): https://www.docker.com/products/docker-sandboxes/
- dockur/macos KVM limitation: https://hub.docker.com/r/dockurr/macos/
- Tart: https://tart.run/ · FAQ (Softnet, host reachability): https://tart.run/faq/ · Guest agent / `tart exec`: https://tart.run/blog/2025/06/01/bridging-the-gaps-with-the-tart-guest-agent/
- Antigravity permissions & sandbox: https://antigravity.google/docs/agent-settings/ · https://antigravity.google/docs/sandbox/ · Headless CLI: https://antigravity.google/docs/cli/headless/
- Perplexity SPACE sandbox (egress bypass data): https://www.marktechpost.com/2026/10/16/perplexity-open-sources-space-firecracker-microvm-sandbox-ai-agents/
- Anthropic reward-hacking disclosure: https://techcrunch.com/2026/10/09/anthropic-cant-reliably-control-its-ai-agents-its-cutting-off-its-internal-evals-from-the-live-internet-instead/
