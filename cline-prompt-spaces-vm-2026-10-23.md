# Cline task — Spaces-on-VM implementation, Steps A–C (2026-10-23)

Read first: `apexagent-spaces-vm-design.md` (repo root), especially the **Decisions (2026-10-23)** section, which overrides anything conflicting in the design body. Also read `~/ApexSandbox/SETUP_REPORT.md` and `~/ApexSandbox/run.sh` — they are the working reference for tart invocations, VM sizing, and network flags.

Owner authorisation for THIS work (Daniel, 2026-10-23): you may **commit and merge when the full gate is green** (clean build + full unit plan + SwiftSyntaxLintGate solo). Report every commit hash and merge in the report file. Tests are add-only: never weaken, delete, or skip an existing test — if an existing test blocks you, stop and report it.

## Step A — Land the Oct 22 fix loop (prerequisite)

1. Re-run the full unit plan once and confirm it matches the verified state in `CODEX_FIXES_2026-10-22.md` (1691 run / 1687 passed / 0 failed / 4 skipped). If it does not match, STOP and report — do not commit.
2. Commit all current working-tree changes on branch `fix/oct20-test-fixes` with message: `Oct 22 audit fix pass F1–F13 (unit plan 1691/1687/0/4, lint gate passed)`.
3. Merge PR #29 into `main`: use `gh pr merge 29 --merge`. If `gh` is missing/unauthed, or the merge conflicts, STOP and report exactly what happened — do not improvise a different merge path.
4. Create branch `feat/spaces-vm` from the updated `main` and switch to it. All remaining steps happen on this branch.

## Step B — Phase 0 probes (confirmatory; report outputs verbatim)

1. `tart --version` and `tart list`.
2. `tart exec --help` — confirm the subcommand exists.
3. Smoke test on a THROWAWAY clone (never boot `apex-base` for work): `tart clone apex-base apex-probe`, boot it the way run.sh does (`tart run --net-softnet`, display enabled), wait for the IP, then via `tart exec apex-probe`: `echo ok`, `xcodebuild -version`, `swift --version`. Then `tart stop apex-probe` and `tart delete apex-probe`.
4. If any probe fails, STOP and report — do not proceed to Step C.

## Step C — Phase 1: per-Space VM lifecycle (no tool routing yet)

Owner decision (revised 2026-10-23 08:07 CT — an earlier shared-VM call was reversed in favour of the design recommendation): **VM PER SPACE**. Each Space gets its own Tart clone of `apex-base`, named `apex-space-<spaceID>`. Sizing from SETUP_REPORT: 8 vCPU, 10240 MB. Network: `--net-softnet`. At most 2 VMs running at once (Apple limit) — refuse or queue beyond that.

1. New file `ApexAgent/Models/TartCLIClient.swift`:
   - Resolves the real tart binary (follow the Homebrew path to `tart.app/Contents/MacOS/tart`; the app must invoke the real binary so Tart uses its own embedded provisioning profile).
   - Async API, argument arrays only (never interpolate user text into a shell string): `clone(source:name:)`, `set(name:cpu:memoryMB:)`, `run(name:softnet:)`, `exec(name:arguments:) -> (stdout, stderr, exitCode)` with streamed output, `ip(name:)`, `stop(name:)`, `delete(name:)`, `list() -> [VMInfo]`.
   - Typed errors. All calls go through Foundation `Process`.
2. New file `ApexAgent/Models/VMWorkspaceManager.swift`:
   - Manages per-Space VMs `apex-space-<spaceID>`: `provision(spaceID:)` (clone from `apex-base` if missing; apply cpu/memory), `start(spaceID:)` (tart run with Softnet, display enabled per run.sh; poll `tart exec … echo ok` until ready, with timeout), `stop(spaceID:)`, `destroy(spaceID:)`, `status` for all managed VMs.
   - It is an actor. Operations serialise through it; heavy operations (build/test class) take a per-VM exclusive lock. At most 2 VMs running at once — starting a third must refuse or queue, never exceed.
   - The per-Space checkout/worktree wiring inside the guest is Phase 2 — do NOT build it now. This step is lifecycle + status only.
3. Register both files in the project the same way sibling Models files are registered (project.yml / xcodegen if that is the mechanism in use).
4. Unit tests, add-only: pure-function coverage for TartCLIClient argument construction, VM naming, and output parsing; VMWorkspaceManager state transitions against a protocol-injected fake Tart client. No test may boot a real VM.

## Finish (Step C gate)

- Clean build, full unit plan with `-resultBundlePath` (report exact totals via xcresulttool), SwiftSyntaxLintGate solo.
- Commit on `feat/spaces-vm` ONLY if everything is green, message: `Spaces-on-VM Phase 1: TartCLIClient + per-Space VMWorkspaceManager lifecycle`.
- Write `SPACES_VM_IMPLEMENTATION_2026-10-23.md` in the repo root: Step A results (plan totals, commit hash, PR #29 merge outcome), Step B probe outputs verbatim, Step C files/tests added, final verification totals, a Deviations section, and a NOT DONE section (Phases 2–3: execution routing, gate/landing).
- Then STOP. Phases 2–3 are a separate task.

## Hard rules

- Never boot, modify, or delete `apex-base`. Clone from it only.
- Never mount the real repo into any VM; never pass `--dir` pointing at the repo.
- Do not touch ToolDispatchEngine, the tools, SpaceManager, or any UI in this task.
- If the unit plan regresses because of your new code, fix your code or remove it — never edit an existing test to make it pass.
