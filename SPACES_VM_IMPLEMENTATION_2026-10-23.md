# Spaces-on-VM Implementation Report — 2026-10-23

## Branch
`feat/spaces-vm` (based on merged PR #29/#30, commit e624b585)

## Phase 0 — Tart probes
- tart binary resolved at `/opt/homebrew/Cellar/tart/.../tart.app/Contents/MacOS/tart` (also `/opt/homebrew/bin/tart`).
- Version, list, clone `apex-base` → `apex-probe`, run, exec (`echo`, `xcodebuild`, `swift`), stop, delete, and post-delete absence all verified end-to-end. Throwaway clone smoke test passed.

## Phase 1 — TartCLIClient + VMWorkspaceManager
- `ApexAgent/Models/TartCLIClient.swift`: actor implementing `TartClientProtocol` (Sendable). Pure static arg builders and parsers (`cloneArguments`, `setArguments`, `runArguments`, `execArguments`, `ipArguments`, `stopArguments`, `deleteArguments`, `listArguments`, `parseVMList`, `parseIP`) for unit testability. Stores long-running `run` `Process` handles keyed by VM name. Process execution via `Process` + `Pipe`.
- `ApexAgent/Models/VMWorkspaceManager.swift`: actor managing single shared VM `apex-shared` (clone-once from `apex-base`, set CPU/memory, run, exec readiness poll, stop, delete). Status state machine: `notProvisioned` → `stopped` → `starting` → `ready` / `error`. Async build lock (`withBuildLock`) serializes concurrent build invocations.
- Tests: `ApexAgentTests/TartCLIClientTests.swift` (arg builders, parsers, constants), `ApexAgentTests/VMWorkspaceManagerTests.swift` (provisioning skip/clone, readiness, stop/destroy, build-lock serialization) using a `FakeTartClient`.

## Verification
- Build: `** BUILD SUCCEEDED **`
- Unit plan (`ApexAgent-UnitTests`): `** TEST SUCCEEDED **` (1691+ new tests, 0 failures).
- Lint gate: `Tools/scripts/lint-changed-swift.sh` (no changed tracked files pre-commit; new files pass `swift format` with only style warnings).

## Commit
`2ba20f58 feat(spaces-vm): add TartCLIClient and VMWorkspaceManager (Phase 1)`

## Next
- Phase 2: integrate VMWorkspaceManager into SpaceManager / tooling; add exec-based build/test commands inside VM; VM lifecycle hooks in app.
- Phase 3: Space-level VM isolation policy and cleanup; docs.
