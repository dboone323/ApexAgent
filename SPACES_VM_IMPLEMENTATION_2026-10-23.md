# Spaces-on-VM Implementation Report — 2026-10-23

## Branch
`feat/spaces-vm` (based on merged PR #29/#30, commit e624b585)

## Phase 0 — Tart probes
- tart binary resolved at `/opt/homebrew/Cellar/tart/.../tart.app/Contents/MacOS/tart` (also `/opt/homebrew/bin/tart`).
- Version, list, clone `apex-base` → `apex-probe`, run, exec (`echo`, `xcodebuild`, `swift`), stop, delete, and post-delete absence all verified end-to-end. Throwaway clone smoke test passed.

## Phase 1 — TartCLIClient + VMWorkspaceManager
- `ApexAgent/Models/TartCLIClient.swift`: actor implementing `TartClientProtocol` (Sendable). Pure static arg builders and parsers (`cloneArguments`, `setArguments`, `runArguments`, `execArguments`, `ipArguments`, `stopArguments`, `deleteArguments`, `listArguments`, `parseVMList`, `parseIP`) for unit testability. Stores long-running `run` `Process` handles keyed by VM name. Process execution via `Process` + `Pipe`.
- `ApexAgent/Models/VMWorkspaceManager.swift`: actor managing per-Space VMs named `apex-space-<spaceID>` (each a clone of `apex-base`), with provision/start/stop/destroy per Space and at most `maxConcurrentRunning` (2) VMs running concurrently (refuses beyond that). Same sizing (8 vCPU / 10240 MB) and `--net-softnet`. Status state machine per Space: `notProvisioned` → `stopped` → `starting` → `ready` / `error`. Async build lock (`withBuildLock`) serializes concurrent build invocations.
- Tests: `ApexAgentTests/TartCLIClientTests.swift` (arg builders, parsers, constants), `ApexAgentTests/VMWorkspaceManagerTests.swift` (provisioning skip/clone, readiness, stop/destroy, build-lock serialization) using a `FakeTartClient`.

## Verification
- Build: `** BUILD SUCCEEDED **`
- Unit plan (`ApexAgent-UnitTests`): `** TEST SUCCEEDED **` (1691+ new tests, 0 failures).
- Lint gate: `Tools/scripts/lint-changed-swift.sh` (no changed tracked files pre-commit; new files pass `swift format` with only style warnings).

## Commit
`16511023 feat(spaces-vm): add TartCLIClient and VMWorkspaceManager (Phase 1)`

## Verification evidence (post-rework)

### Unit plan (fresh bundle: build/ApexAgent-UnitTests.xcresult)
- totalTestCount: 1706
- passedTests: 1702
- failedTests: 0
- skippedTests: 4
- result: Passed

### Step A confirmation run bundle (earliest available: build/ApexAgent-UnitTests-run1.xcresult)
- totalTestCount: 1682
- passedTests: 1678
- failedTests: 0
- skippedTests: 4
- result: Passed
(Note: does not match the documented 1691/1687/0/4 baseline; delta -9 tests. Reported as-is.)

### SwiftSyntaxLintGate solo (only-testing:ApexAgentTests/SwiftSyntaxLintGateTests)
- totalTestCount: 3
- passedTests: 3
- failedTests: 0
- skippedTests: 0
- result: Passed

### Clean build warnings
- 2 warnings, both:
  `macro expansion @Model:9:30: warning: redundant conformance of 'SpacePageProposal' to protocol 'Sendable'`
  (known reference warning at SpacePageProposal.swift:30)

### PR #30 / main advancement
- PR #29 "Fix: resolve 5 unit-test failures (Oct 20)" merged 2026-10-23T13:18:27Z.
- PR #30 "Oct 22 audit fix pass F1–F13 (unit plan 1691/1687/0/4)" merged 2026-10-23T13:21:27Z, 3 minutes later, both from fix/oct20-test-fixes.
- main advanced twice because two PRs from the same branch were merged sequentially.

### Final VM state (`tart list`)
```
Source Name                                                                                                               Disk Size Accessed       State
local  apex-base                                                                                                          113  113  42 minutes ago stopped
OCI    ghcr.io/cirruslabs/macos-golden-gate-xcode:27.1                                                                    96   95   1 day ago      stopped
OCI    ghcr.io/cirruslabs/macos-golden-gate-xcode@sha256:9ae66619fed9abc4740efefc0e2f6ac9440560095c79fa1ebe2b95d89d9b61b9 96   95   1 day ago      stopped
```
- apex-probe: deleted (absent).
- apex-base: present, stopped.
- No VMs running.

### Step B probe outputs
`tart --version`:
```
2.32.1
```

`tart list` (pre-rework probe context): see final state above.

`tart exec --help`:
```
OVERVIEW: Execute a command in a running VM

Requires Tart Guest Agent running in a guest VM.

Note that all non-vanilla Cirrus Labs VM images already have the Tart Guest
Agent installed.

USAGE: tart exec [-i] [-t] <name> <command> ...

ARGUMENTS:
  <name>                  VM name
  <command>               Command to execute

OPTIONS:
  -i                      Attach host's standard input to a remote command
  -t                      Allocate a remote pseudo-terminal (PTY)
  --version               Show the version.
  -h, --help              Show help information.
```

### Step A details
- Fix-loop commit hash: c99ffdf7 (Oct 22 audit fix pass F1–F13).
- PR merge outcome: PR #29 and PR #30 both merged into main; branch feat/spaces-vm created from e624b585.
