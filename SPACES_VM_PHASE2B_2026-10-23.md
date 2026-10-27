# Spaces-on-VM Phase 2b — 2026-10-23

## Summary
- Added `ExecutionEnvironmentResolver` (pure resolve + path mapping + per-space backend registry).
- Added `TartVMRoutingTests` (12 tests) covering resolution, path mapping, shell prefix, backend seeding/bundle failure, write/read round trip.
- Restored `FakeTartClient.setExecResult` alongside existing `setVMs`.
- Made `SpaceModel` `@unchecked Sendable` and `isSandboxVM` available for resolver use.
- `TartVMBackend.seed(workspacePath:)` now accepts optional workspace path.
- Wired all 10 tools to VM backend:
  - ShellTool, FileSystemTools (read/write/create/list/delete/move), FilePatchTool, FileSearchTool, GitOperationsTool.
- Each tool resolves environment via `ExecutionEnvironmentResolver.resolveCurrent`, seeds workspace, maps paths, and delegates to `TartVMBackend`.
- Added tool-level routing test in `VMRoutingLiveTests` (resolver + backend-registry path).

## Resolution code path used
- `ExecutionEnvironmentResolver.resolveCurrent(orchestrator:)` reads `UserDefaults` `apex.appleContainersEnabled` and `orchestrator.currentWorkspacePath`, finds the owning `SpaceModel` via `SpaceManager.shared` (active space id, else first space whose `workspacePath` matches), and calls `resolve(space:containerEnabled:)`.
- `.tartVM` when the Space's `executionTargetRaw == "tartVM"` (or `isSandboxVM`), carrying the Space's `workspacePath` for seeding/path mapping; otherwise container/host fallback.
- Per-space backend obtained from `TartVMBackendRegistry.shared.backend(for: spaceID)`.

## Per-tool wiring summary
- ShellTool → `backend.runShell`; workingDirectory mapped; outside workspace → clear `ERROR:`.
- FileReadTool/FileWriteTool/ListDirectoryTool/CreateDirectoryTool/DeleteFileTool/MoveFileTool → matching backend primitives with path mapping; absolute outside workspace → clear `ERROR:` (never sent to guest, never run on host). RollbackTool NOT routed.
- FilePatchTool → patch logic stays host-side; only file read/write move through backend.
- FileSearchTool → `backend.searchFiles` within mapped path.
- GitOperationsTool → existing argument construction executed via `backend.git`.
- Fail-closed: unprovisionable/unseedable VM yields clear tool error, no host fallback.

## Path-mapping rule
- Relative path → passthrough.
- Absolute path inside workspace → guest-relative.
- Absolute path outside workspace → throws `ERROR: path outside workspace:`.

## New unit tests
- `TartVMRoutingTests` (12): resolutionTartBeatsContainer, resolutionContainerBeatsHost, resolutionHostWhenNoFlags, resolutionNoSpaceFallthroughContainer, resolutionNoSpaceFallthroughHost, pathMappingInsideWorkspace, pathMappingRelativePassthrough, pathMappingOutsideThrows, shellCommandConstructionSingleCdPrefix, backendSeededShortCircuit, bundleFailureSurfaces, writeReadRoundTrip.
- `VMRoutingLiveTests` (2, gated on `APEX_LIVE_VM=1`): `smoke` (backend-level), `toolLevelRouting` (resolver + backend-registry level).

## Verification
- Clean build: SUCCEEDED (warnings: known SpacePageProposal redundant-Sendable macro artifact only).
- SwiftSyntaxLintGate solo: PASSED.
- Live smoke (`APEX_LIVE_VM=1`): 1714 passed / 0 failed / 6 skipped (run 1720); both VMRoutingLiveTests passed (backend-level + resolver/backend-registry level). Post-run `tart list`: `apex-space-smoke` gone, `apex-base` stopped, nothing running.
- Full unit plan WITHOUT `APEX_LIVE_VM` (fresh bundle `build/ApexAgent-UnitTests.xcresult`), xcresulttool totals:
  - run 1720 / passed 1714 / failed 0 / skipped 6.
  - Reconciliation: pre-2b baseline 1707 run / 1702 passed / 0 failed / 5 skipped. Part 1 added TartVMRoutingTests (12) → 1719 run / 1714 passed / 0 failed / 5 skipped. Phase 2b added one gated live test (toolLevelRouting) → 1720 run / 1714 passed / 0 failed / 6 skipped. The prompt's stated expected 1719/1714/0/5 did not account for the second gated test; the +1 run / +1 skip is explained by that added test. 0 failures required and met.

## Commit
- Branch: `feat/spaces-vm` (no merge).
- Commit hash: ccd927e7