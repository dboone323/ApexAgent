# Spaces-on-VM Phase 2b — Wire the tools to TartVMBackend + routing unit tests

Branch: `feat/spaces-vm` (do not switch branches; do NOT merge this branch into anything).
Context: Phase 2 (commit `b0159f42`, report `SPACES_VM_PHASE2_2026-10-23.md`) built the backend but did NOT wire the tools, and its required routing unit tests were never written. The owner's reviewer verified this directly: `ShellTool.swift` was read in full and contains no `.tartVM` branch, and the unit-plan passed total did not move (1702 before and after Phase 2 — the only new test was the 1 gated live test). The owner approved this Phase 2b on 2026-10-23 to close both gaps before Phase 3.

## What already exists (verified — build on it, do not rebuild it)
- `ApexAgent/Models/ExecutionEnvironment.swift`: `enum ExecutionEnvironment { case host, appleContainer, tartVM(spaceID: String) }`.
- `SpaceModel.executionTargetRaw` (default `"host"`) + `executionTarget` / `isSandboxVM` accessors in `ApexAgent/Models/SpaceModels.swift`.
- `ApexAgent/Models/TartVMBackend.swift`: actor with `runShell` (adds `cd '<guestCheckout>' &&` prefix, guest checkout `~/ApexAgent`), file primitives (`readFile`, `writeFile`, `deleteFile`, `moveFile`, `listDirectory`, `createDirectory`, `searchFiles`), `git(arguments:)`, and seeding via host `git bundle` → `execStdin` → guest `git bundle verify` → clone → checkout of the recorded branch. Fail-closed: non-git workspace or missing workspace path throws; there is no silent host fallback. Note: its internal `runRaw` calls `seedIfNeeded()` WITHOUT a workspace path, so a caller must supply the path (see 2c).
- `TartCLIClient.execStdin` (tart exec -i) exists.
- `ApexAgentTests/VMRoutingLiveTests.swift`: gated on `APEX_LIVE_VM=1`, exercises the BACKEND directly against a scratch repo (passing). Phase 2b adds a tool-level/routing-level live test (see 4).
- Tools are constructed ONCE in `ToolDispatchEngine.buildAllTools(orchestrator:botManager:)` with only `orchestrator: OrchestratorProvider` — there is no per-Space tool construction. Resolution must therefore happen at CALL time through the orchestrator, the same way `ShellTool` already reads `orchestrator.currentWorkspacePath` and `orchestrator.currentConversation`.

## Where the routed tools live
- `ApexAgent/Tools/ShellTool.swift` — ShellTool (`run_shell_command`). Read in full during review: it branches only on `apex.appleContainersEnabled` and `apex.microvmSandboxEnabled`, then PTY/host Process. Those branches must stay untouched.
- `ApexAgent/Tools/FileSystemTools.swift` — FileReadTool, FileWriteTool, ListDirectoryTool, CreateDirectoryTool, DeleteFileTool, MoveFileTool — and RollbackTool, which must NOT be routed.
- `ApexAgent/Tools/FilePatchTool.swift` — FilePatchTool.
- `ApexAgent/Tools/FileSearchTool.swift` — FileSearchTool.
- `ApexAgent/Tools/GitOperationsTool.swift` — GitOperationsTool.

## Work

### 1. Shared environment resolution (one place, used by every routed tool)
Add a single resolution helper (e.g. `ExecutionEnvironmentResolver`, in Models or a fitting existing location). At call time, given the orchestrator:
- Find the Space that owns the current conversation/workspace. Use whatever the codebase already provides (orchestrator / SpaceManager). In the report, state the exact code path you used.
- If that Space's `executionTarget` is `.tartVM` → resolve `.tartVM(spaceID: space.id.uuidString)` and carry the Space's `workspacePath` for seeding and path mapping.
- Else if `apex.appleContainersEnabled` is true → `.appleContainer`.
- Else → `.host`.
- If there is NO Space context, fall through to the container/host checks exactly as the tools behave today.
Keep the decision itself a pure, unit-testable function of (space target, container flag); keep the live lookup thin.

### 2. Wire the 10 routed tools
For each of ShellTool, FileReadTool, FileWriteTool, FilePatchTool, DeleteFileTool, MoveFileTool, ListDirectoryTool, CreateDirectoryTool, FileSearchTool, GitOperationsTool: when the resolved environment is `.tartVM`, execute through `TartVMBackend`; when it is `.host` or `.appleContainer`, run the existing code path with unchanged behaviour.
- Path mapping (shared helper, unit-tested): an absolute host path inside the Space's `workspacePath` maps to the corresponding guest-relative path; a relative path is interpreted relative to the guest checkout; an absolute path OUTSIDE the workspace is a clear `ERROR:` result — never sent into the guest, never silently executed on the host.
- ShellTool: route via `backend.runShell`. Honour the timeout argument as far as the backend supports it. The `workingDirectory` argument: inside the workspace → map into the guest; outside → `ERROR:` and do not execute. (The backend already adds the guest-checkout `cd` prefix; do not double-prefix.)
- FilePatchTool: keep the patch/transformation logic host-side; only the file read/write move through the backend.
- FileSearchTool: search within the mapped path via `backend.searchFiles`.
- GitOperationsTool: keep its existing argument construction; execute via `backend.git`.
- Routing sits BELOW the confirmation/risk layer: do not change `ToolDispatchEngine.shouldConfirmTool`, `AgentSecurity`, the risk map, or `executeWithLogging` semantics.

### 2c. Backend instances and seeding
One `TartVMBackend` per spaceID, created on demand and reused. The first routed call for a Space must supply the Space's `workspacePath` so seeding can happen (e.g. call `backend.seed(workspacePath:)` before first use, or extend the backend minimally so the path is provided at construction/first use). Preserve the backend's fail-closed errors — a VM that cannot be provisioned/seeded produces a clear tool error, never a host fallback.

### 3. Explicitly NOT routed — do not touch
SpotlightSearchTool (host index), RollbackTool (host snapshot store), GitHubTool (remote API), MCP/dynamic tools, and every other tool. Do not add the Spaces UI toggle (owner deferred it). Do not change app-sandbox (stays false) or the Team ID.

### 4. Unit tests — the missing Phase 2 coverage (add-only)
New file `ApexAgentTests/TartVMRoutingTests.swift`, registered the same way Phase 2's files were (project.yml / xcodegen — do NOT hand-patch project.pbxproj). Reuse/extend the `FakeTartClient` pattern from `VMWorkspaceManagerTests`. Cover at least:
- Resolution precedence: `.tartVM` beats container flag; container beats host; no-Space fallthrough matches today's behaviour.
- Path mapping: inside-workspace absolute → guest-relative; relative passthrough; outside-workspace absolute → error.
- Shell command construction for the VM path (guest `cd` prefix present exactly once).
- Backend vs fake client: already-seeded short-circuit (the `test -d ~/ApexAgent/.git` check), bundle-failure error surfaces, write/read round trip through captured `execStdin` input.
Tests are add-only: never weaken, delete, or skip an existing test; flag problems instead.

### 5. Live smoke (gated)
Extend `VMRoutingLiveTests.swift` (same `APEX_LIVE_VM=1` gate) with a tool-level test: resolve a `.tartVM` environment for the smoke Space through the SAME helper the tools call, then execute at least a shell operation and one file-tool operation end-to-end against the scratch repo in the guest. If constructing a full tool requires disproportionate app scaffolding, exercise the shared routing layer the tools call and state precisely in the report which level was exercised and why. Afterwards `tart list` must show `apex-space-smoke` gone, `apex-base` stopped, nothing running.

### 6. Finish gate (all required before committing)
- Clean build; state warnings (baseline: 2, both the known SpacePageProposal redundant-Sendable macro artifact).
- Full unit plan WITHOUT `APEX_LIVE_VM`, exact totals via xcresulttool from a FRESH bundle. Baseline: 1707 run / 1702 passed / 0 failed / 5 skipped. Passed MUST rise by exactly the number of new unit tests you added, and run must rise by the same; any other delta must be explained in the report.
- SwiftSyntaxLintGate solo: pass.
- Live suite with `APEX_LIVE_VM=1`: all passing, with the post-run `tart list` state above.

### 7. Commit + report
Only if the gate AND the live smoke are green, commit on `feat/spaces-vm` (the owner's scoped authorisation for Spaces-VM work covers this commit; it does NOT cover merging the branch):
`Spaces-on-VM Phase 2b: wire tools to TartVMBackend + routing unit tests`
Write `SPACES_VM_PHASE2B_2026-10-23.md` in the repo root: resolution code path used; per-tool wiring summary; path-mapping rule as implemented; new unit tests listed by name with the count; exact gate totals; live smoke evidence including which level (tool vs routing layer) was exercised; deviations, if any. Then STOP.
