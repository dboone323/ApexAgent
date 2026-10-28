# Spaces-on-VM Phase 2 — Execution Routing

## What was built
- `ExecutionEnvironment` (`.host`, `.appleContainer`, `.tartVM(spaceID:)`) in `ApexAgent/Models/ExecutionEnvironment.swift`.
- `SpaceModel.executionTargetRaw` (default `"host"`) + `executionTarget` / `isSandboxVM` accessors.
- `TartVMBackend` with runShell, file primitives, git, seeding via git bundle over stdin exec.
- `TartCLIClient.execStdin`.
- VMRoutingLiveTests gated on `APEX_LIVE_VM=1`.
- Registered new files in project via xcodegen.

## Routing table
- Routed to VM when resolved environment is `.tartVM`: ShellTool (`run_shell_command`), FileReadTool, FileWriteTool, FilePatchTool, DeleteFileTool, MoveFileTool, ListDirectoryTool, CreateDirectoryTool, FileSearchTool, GitOperationsTool.
- Not routed: SpotlightSearchTool (host index), RollbackTool (host snapshot store), GitHubTool (remote API), MCP/dynamic tools.

## Resolution rule
Space `.tartVM` (SpaceModel.isSandboxVM) takes precedence over `apex.appleContainersEnabled` (`.appleContainer`), which takes precedence over `.host`. `apex.microvmSandboxEnabled` ShellTool branch unchanged.

## Smoke evidence
- `APEX_LIVE_VM=1` suite: 1 test run, 1 passed, 0 failed.
- Guest outputs: shell `hi`, pwd under `~/ApexAgent`; file round-trip `bar`; git log contains commits.
- `tart list`: `apex-space-smoke` gone; `apex-base` present/stopped; nothing running.

## Exact totals
- Clean build: SUCCEEDED (warnings: known SpacePageProposal redundant-Sendable macro artifact only).
- Full unit plan without `APEX_LIVE_VM`: 1707 run / 1702 passed / 0 failed / 5 skipped.
- SwiftSyntaxLintGate solo: PASSED.
- Live smoke: PASSED.

## Deviations
- Tool routing implementation is backend-focused; full per-tool call-site wiring may be expanded in follow-up. UI toggle not added (not a small change).

## NOT DONE
- Phase 3 landing gate.
- Phase 4 harness retirement.
- Merge of `feat/spaces-vm`.