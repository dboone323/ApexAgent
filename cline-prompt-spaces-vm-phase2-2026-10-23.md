# Cline task — Spaces-on-VM Phase 2: execution routing (2026-10-23)

Context: Phase 1 is committed on `feat/spaces-vm` (16511023 + docs): TartCLIClient + per-Space VMWorkspaceManager (`apex-space-<spaceID>`, max 2 running). Read `apexagent-spaces-vm-design.md` (Architecture + Phasing) and `SPACES_VM_IMPLEMENTATION_2026-10-23.md` first. Work on `feat/spaces-vm`.

SCOPE: Phase 2 ONLY — routing. No landing gate (Phase 3), no harness retirement (Phase 4), no merging of feat/spaces-vm.

## 1. ExecutionEnvironment + per-Space opt-in
- New type `ExecutionEnvironment` (Equatable, Sendable): `.host`, `.appleContainer`, `.tartVM(spaceID: String)`. Place it where it fits the existing layout (Models/ or Coordinators/).
- `SpaceModel` (Models/SpaceModels.swift): add `executionTargetRaw: String` defaulting to `"host"` (values `host` | `tartVM`), following the existing `defaultOrchestrationModeRaw` pattern, plus a typed computed accessor. The default value must let existing SwiftData stores migrate untouched.
- Resolution rule: a tool resolves its environment from the Space in whose context it runs. Investigate how Space context reaches tool execution (AgentOrchestrator, SpaceThreadDispatcher, SpaceManager) and implement resolution at that seam; state the exact rule you implemented in the report. Precedence: Space `.tartVM` > `apex.appleContainersEnabled` flag (`.appleContainer`) > `.host`. The `apex.microvmSandboxEnabled` branch in ShellTool stays exactly as-is.
- UI: if SpacesViews.swift already has a Space settings surface where this is a small addition, add a "Run in sandbox VM" toggle bound to the new property. If it is not a small change, skip the UI and say so in the report.

## 2. TartVMBackend + seeding
- New file `ApexAgent/Models/TartVMBackend.swift`. Given a spaceID it provides:
  - `runShell(command:timeout:)` → runs via TartCLIClient.exec in the guest checkout, prefixing `cd '<guestCheckout>' &&` with the same single-quote escaping ShellTool uses. Returns (stdout, stderr, exitCode).
  - File primitives for the routed file tools: read, write, delete, move, list, createDirectory, search. Keep each tool's transformation logic (e.g. FilePatchTool's patch computation) host-side — only the I/O moves into the guest.
  - `git(arguments:)` → `git -C '<guestCheckout>' ...` via runShell.
- Guest checkout path: `~/ApexAgent` in the guest (per the design doc).
- TartCLIClient: add an exec variant that feeds stdin (`tart exec -i`, Process with a stdin Pipe) for raw-byte transfers.
- Seeding (once per VM, before first routed call; detect via a guest-side check such as `test -d ~/ApexAgent/.git`):
  1. On the host, create a git bundle of the Space's `workspacePath` repo: `git -C <workspacePath> bundle create <tmpfile> HEAD` and record the current branch name.
  2. Transfer the bundle into the guest via the stdin exec (`cat > /tmp/seed.bundle`).
  3. In the guest: `git bundle verify /tmp/seed.bundle`, then `git clone /tmp/seed.bundle ~/ApexAgent` and check out the recorded branch.
  4. If `workspacePath` is not a git repo, seeding fails and the tool call returns a clear ERROR — never fall back to silent host execution.
- VM lifecycle goes through VMWorkspaceManager (provision + startIfNeeded). If the VM cannot be made ready, routed calls return a clear ERROR string; never execute on the host instead.

## 3. Routing (mirror the ShellTool container-branch precedent)
- Confirmations and the risk map sit ABOVE execution and are untouched: routing changes only where an already-approved call executes.
- Route when the resolved environment is `.tartVM`: ShellTool (`run_shell_command`), FileReadTool, FileWriteTool, FilePatchTool, DeleteFileTool, MoveFileTool, ListDirectoryTool, CreateDirectoryTool, FileSearchTool (implement guest-side with find/grep via runShell, same parameters), GitOperationsTool.
- Do NOT route: SpotlightSearchTool (host Spotlight index), RollbackTool (host snapshot store), GitHubTool (remote API), and everything else by default. MCP / dynamically discovered tools are never routed.
- Path semantics: tool path arguments are relative to the Space's workspace root and map into the guest checkout. An absolute host path must be rejected with a clear error, never passed through to the guest.

## 4. Tests (add-only — never edit, weaken, or delete an existing test)
- Unit tests: environment precedence/resolution; shell command construction (cd prefix + escaping); path mapping (relative → guest checkout; absolute host path rejected); seeding command sequence against a fake Tart client; routing decisions if you factor a helper for them.
- Live tests: new file `ApexAgentTests/VMRoutingLiveTests.swift`, gated on the `APEX_LIVE_VM=1` environment variable in the same style as LiveBotCommunicationTests (skipped when unset). It must: create a scratch git repo (a couple of commits) in a temp directory; provision the VM for spaceID `smoke`; seed it; run one shell command (echo + pwd) through TartVMBackend; write and read back a file; run git log; assert the outputs; destroy the VM in teardown.

## 5. Live smoke run (required — unit evidence alone does not finish Phase 2)
- Run the gated suite once with `APEX_LIVE_VM=1` and capture the full result into the report (tests run/passed/failed + the key guest outputs).
- Afterwards confirm with `tart list`: `apex-space-smoke` is gone, `apex-base` present and stopped, nothing running.
- If the smoke fails, fix within Phase 2 scope or STOP and report. Do not commit a Phase 2 without the smoke passing.

## 6. Docs fix
- In `SPACES_VM_IMPLEMENTATION_2026-10-23.md`, correct the Commit section: `2ba20f58` → `16511023` (the earlier hash was an orphaned draft commit that was reset before the final Phase 1 commit).

## Finish gate (exact numbers from a fresh `-resultBundlePath`, parsed with xcresulttool)
- Clean build SUCCEEDED; state the warnings (expected: only the known SpacePageProposal redundant-Sendable macro artifact).
- Full unit plan WITHOUT `APEX_LIVE_VM`: report run / passed / failed / skipped. Baseline is 1706 / 1702 / 0 / 4 — the new totals must show 0 failures, your added tests in the run count, and the live suite's skips accounted for.
- SwiftSyntaxLintGate solo: pass/fail stated explicitly.
- Commit on `feat/spaces-vm` ONLY if the gate AND the live smoke are green, message: `Spaces-on-VM Phase 2: ExecutionEnvironment routing for VM-bound Spaces`
- Write the report `SPACES_VM_PHASE2_2026-10-23.md` (repo root): what was built, the routing table (tool → routed or not, and why), the resolution rule, smoke evidence, exact totals, deviations, and NOT DONE (Phase 3 gate/landing, Phase 4 harness retirement). Then STOP.

## Hard rules
- Tests are add-only. If a new test exposes a bug in existing code, fix the code, never the existing test.
- Never boot, modify, or delete `apex-base` — clone from it only. Never mount a real repo into a VM (no `--dir` at any repo). At most 2 VMs running at once.
- Do not change the behaviour of the confirmation / risk-map layer.
- Do not merge `feat/spaces-vm` anywhere. Commits on `feat/spaces-vm` only, under the finish gate above.
