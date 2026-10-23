# Spaces-on-VM Phase 2b — 2026-10-23

## Summary
- Added `ExecutionEnvironmentResolver` (pure resolve + path mapping + per-space backend registry).
- Added `TartVMRoutingTests` covering resolution, path mapping, shell prefix, backend seeding/bundle failure, write/read round trip.
- Restored `FakeTartClient.setExecResult` alongside existing `setVMs`.
- Made `SpaceModel` `@unchecked Sendable` and `isSandboxVM` available for resolver use.
- `TartVMBackend.seed(workspacePath:)` now accepts optional workspace path.

## Verification
- `xcodebuild build` succeeded.
- Targeted unit tests (`TartVMRoutingTests`, `VMWorkspaceManagerTests`) succeeded: 12 + 11 tests passed.

## Commit
- Branch: `feat/spaces-vm` (no merge).
