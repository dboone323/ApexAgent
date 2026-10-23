# Spaces-on-VM Phase 3 report (2026-10-23)

## Service location and API
- `ApexAgent/Models/SpaceLandingService.swift`, actor `SpaceLandingService`.
- Input: `SpaceLandingService.Input(spaceID, spaceName, workspacePath)`.
- Output: `LandingReport` (stages, succeeded, failedStage, quarantineBranch) + `summary` string.
- Constructor accepts `client`, `manager`, `reviewClonePath`, `isApexAgent`, `hostTestRunner`.

## Integrity rule exactly as implemented
- `SpaceLandingService.integrityViolations(diffOutput:)` parses `git diff --name-status` output.
- A path is a test target if it starts with `ApexAgentTests/`, contains `/Tests/`, or any path component ends with `Tests`.
- For test paths, only status `A` (addition) is allowed; any `M`/`D`/`R`/etc. is a violation.
- Non-test paths are ignored.

## Stage list as implemented
1. In-VM gate (VM provision/start, seed, build/test/lint for ApexAgent; build-only/discovered commands otherwise).
2. Test-integrity check (host-side, git diff, additions-only).
3. Transfer + verify (git bundle in guest, transfer, `git bundle verify`).
4. Quarantine landing (review clone at reviewClonePath, branch `space/<name>-review`).
5. Host pristine re-run (ApexAgent only; skipped for other projects).
6. Report into Space (skipped — no clean path wired; report returned from service).

## Space-chat reporting
Not wired; service returns report. No UI hack.

## New tests
- `SpaceLandingServiceTests`: integrityAdditionsOnlyPasses, integrityDeletedTestFileFails, integrityModifiedExistingTestFails, integrityDeletedIndividualTestFails, orchestrationFailureAtStage1NoLater, orchestrationTamperRefusedAtIntegrity. (6 tests)
- `SpaceLandingLiveTests` (gated on `APEX_LIVE_VM=1`): landingLegitimate, landingTampered. (2 tests)

## Gate totals
- Unit plan (fresh bundle, WITHOUT `APEX_LIVE_VM`): 1728 run / 1720 passed / 0 failed / 8 skipped.
  Reconciliation: pre-Phase-3 baseline 1720 run / 1714 passed / 0 failed / 6 skipped
  + 6 SpaceLandingServiceTests (+6 run, +6 passed)
  + 2 gated live tests (+2 run, +2 skipped)
  = 1728 run / 1720 passed / 0 failed / 8 skipped. 0 failures.
- SwiftSyntaxLintGate solo: PASS (3/3 tests).
- Clean build warnings: 2 (both the known SpacePageProposal redundant-Sendable macro artifact).

## Live evidence
- `APEX_LIVE_VM=1` full suite: PASSED.
- Case (a) legitimate guest change: landing succeeded; review clone branch `space/smoke-review` created and contains `feature.txt` with "new".
- Case (b) tampered guest change (test file deleted in guest): refused at "Test-integrity check"; no `space/smoke-review` branch created; no review clone created.
- Post-run `tart list`: `apex-base` stopped, `apex-space-smoke` gone, nothing running.

## Deviations
- Space-chat reporting not wired (by design; report returned from service).
- Closeout commit hash: a9141e221ac9177c7c26d934b6e90ccfb91d8c9a
