# ApexAgent — Agent Guide

Single source of truth for every AI agent and tool working in this repo
(Cline, Antigravity, GitHub Copilot, Hermes, Ollama-driven sessions, Monarch).
Per-tool shim files point here; if a shim and this file disagree, this file wins.

## The project

- Native macOS application (Swift / Xcode app).
- Environment: macOS 27.0, Swift 6.4, Xcode 27.2.
- Signing & Entitlements: Ad-hoc signing. App sandbox is disabled (`com.apple.security.app-sandbox` is FALSE) — this is a standing architectural fence, never change.
- Local repo: `/Users/danielstevens/Developer/ApexAgent` · GitHub: `dboone323/ApexAgent`

## The loop (how all work moves)

1. **Build** — one branch per task/issue, named `feat/<issue-or-slug>`, `fix/<issue-or-slug>`, or `chore/<issue-or-slug>` (e.g. `feat/45-shared-agent-config`). Open the PR on the first commit; update the same PR with later commits.
2. **Test** — canonical gate is `make lint` then `make test-deep`. Run SOLO. Output is ALWAYS tee'd to a fixed repo-root log.
3. **Issue** — a gate failure, test regression, or out-of-scope problem becomes a GitHub issue with log evidence instead of a chat message that gets lost.
4. **Triage** — triage into lanes: `lane:spine` (critical path/milestone), `lane:targeted-fix` (scoped defect repair), or `lane:continuous` (ongoing maintenance/hygiene). WIP limits: 1 spine, max 2 targeted-fixes, continuous unlimited. At the limit, finishing outranks starting.
5. **Fix → PR** — the PR body carries the evidence and `Fixes #n` (or `Refs #n`) when it addresses an issue.
6. **Review** — Daniel reviews and merges. **No agent merges, ever** (exceptions only per-occasion from Daniel in chat). A new problem found in review becomes a new issue labeled `follow-up`, never scope creep inside the PR.
7. **Deploy / Release** — only from `main`, with Daniel's explicit go.

## The typing rule (every prompt, every issue)

State the type up front, with an objective and done criteria:

- **Goal** — an outcome to reach; done when the end state itself is verified.
- **Problem** — something broken; done when there is red/green proof (the failing test or reproduction first, then passing), a regression test, and a green gate.
- **Feature** — something new; done when it works live in the real product (actually verified in the running application/UI/CLI, not just unit-tested), plus tests and a green gate.

Titles read `[Goal] ...`, `[Problem] ...`, `[Feature] ...` with matching labels `type: goal` / `type: problem` / `type: feature`.

## Issue and PR labels

- `type:` — `type: goal`, `type: problem`, `type: feature`
- `lane:` — `lane:spine` (milestone spine), `lane:targeted-fix` (targeted defect fix), `lane:continuous` (unlimited background/maintenance)
- `status:` — `status:in-progress`, `status:blocked`, etc.
- Area / failure labels: `gate-failure` (from canonical gate), `tech-debt`, `follow-up`, `security`, `ops`, `verification`.
- Lint warnings never get individual issues: they roll into a single standing `tech-debt` issue.
- Every issue states: what failed, the exact command, the failing step, and a log excerpt. No issue without evidence.

## Canonical gate

- The canonical gate sequence:
  1. `make lint`
  2. `make test-deep`
- Output must ALWAYS be tee'd to a fixed repo-root log file (e.g. `test-deep.log`).
- Gates run **SOLO** — never two heavy builds or test suites at once. Before starting, check for running builds/gates and wait for them to finish.
- Save the full gate output to the log file and read it back. Report totals from the log, never from terminal banners or memory.
- Log counts must explicitly declare the method used: **lines vs. occurrences** (e.g. `grep -c` lines vs total match occurrences).
- Zero failed tests is not zero errors — scan the log for runtime errors, crashes, and assertion failures separately.
- Never skip the gate (`PUSH_CI_SKIP` and `--no-verify` are strictly forbidden), and never skip, delete, gate, or weaken a test or bump timeouts to force a green run. A failing or flaky test is reported as-is; the decision about it is Daniel's.
- Git commands: always `git --no-pager`, bounded output, bounded-timeout pushes.

## Evidence standard

- "Done" is a claim about the world, not the diff. Verify from the actual file, log, screenshot, or live product — never from another agent's summary (delegate summaries are claims; verify from files and logs).
- If you report that you wrote, appended, or changed something, re-read the file and confirm before reporting.
- Features are verified live: real interactions in the actual product.

## Hard rules

- **No agent merges, ever**: PR merges are Daniel's responsibility only (exceptions only per-occasion from Daniel in chat).
- **Tests are add-only**: never weaken, delete, skip, gate, or bump timeouts on existing tests.
- **Never bypass CI or git hooks**: never use `PUSH_CI_SKIP=1` or `git push --no-verify`. Pre-push hooks must run and pass.
- **No literal secrets**: never commit or paste credentials, tokens, or private keys in code, workflows, issues, PRs, or chat.
- **Contacts privacy fence**: Contacts access MUST go only via `ContactsOptInManager`. Never access CNContactStore directly outside the opt-in framework.
- **Swift 6 concurrency patterns**:
  - `nonisolated` methods on `@MainActor` classes cannot touch isolated `let` or `var` properties.
  - `[weak self]` is illegal in `@Sendable` closures when `Self` is non-Sendable.
  - Offload blocking work using `Task.detached` with `Sendable` captures only; publish results back via `MainActor.run`.
- **Local CI is the authority**: GitHub Actions cannot execute on this account (runs stay queued; appeal pending). The local gate (`make lint` + `make test-deep`) and pre-push hook ARE the CI.
- **Cline free models only**: only use free models in Cline (`cline-free/` or `reflection/`). Never enable usage-based billing or add credits.
- **Stay inside scope**: an out-of-scope find becomes a GitHub issue, not opportunistic scope creep in the current PR.

## Tool configuration map

| Tool | Configuration File | Notes |
| --- | --- | --- |
| Cline | `.clinerules` | Shim: core non-negotiables pointing to `AGENTS.md` |
| GitHub Copilot | `.github/copilot-instructions.md` | Shim: core non-negotiables pointing to `AGENTS.md` |
| Antigravity | `AGENTS.md` natively + `.agents/rules/apexagent-loop.md` | Antigravity rule @-referencing `AGENTS.md` |
| Hermes | `AGENTS.md` natively | Loads `AGENTS.md` natively — do NOT create `.hermes.md` (it would override `AGENTS.md`) |
| Ollama sessions | via Cline or CLI | Uses Cline's `.clinerules` or repo CLI directly |

Task briefs follow `docs/agent/task-template.md`; failure handling and issue filing rules live in `docs/agent/failure-handling.md`.

## Long-run protocol (no timer polling)

Runs that take minutes (gates, builds, deploys) are never watched on a timer.

1. **Sentinel + exit code.** Every long-running command writes its log to a fixed path AND, on completion, a sentinel file beside it (`<log-name>.done`) containing the exit code and a completion timestamp. The gate/report scripts write the sentinel themselves; ad-hoc runs wrap the command so the sentinel is written on both success and failure.
2. **Blocking waits only.** A supervisor that must wait makes ONE blocking wait for the sentinel, sized to the run's expected duration (gates: ~7–10 min). Polling on a 30-second (or any short) timer across model turns is prohibited — each poll burns a full model turn to learn nothing.
3. **Checkpointed reports.** The worker writes a checkpoint line to the task's report file at each phase boundary (RED done / implementation done / gate started / gate done with totals) and the completion section as its final action. The supervisor reads the report when the worker's turn ends — the turn ending is the completion event.
4. **Failure reading.** If a run dies mid-phase, diagnose from the last checkpoint + the log tail. Never re-run just to watch it.
