# Spaces-on-VM: VM teardown leak paths fix (2026-10-25)

## Housekeeping
- `tart list` before/after: only stopped `apex-base` (113 GiB). No `apex-space-*` VMs present.
- HEAD before: `374f491a Spaces-on-VM: fix tart run arguments, seed readiness, destroy ordering`.

## Fixes

1. `startIfNeeded` timeout cleanup — `ApexAgent/Models/VMWorkspaceManager.swift` (readiness loop tail):
   - On timeout, best-effort `client.stop(name:)` + `client.delete(name:)`, remove from `runningSpaces`, then throw `TartCLIClientError.timeout` (error still propagates).

2. `ensureProvisioned` partial failure — same file:
   - Tracks `cloned` flag; if `clone` succeeds but `set` (or later) throws, best-effort `client.delete(name:)` before rethrowing.

3. `destroy` bookkeeping — same file:
   - `runningSpaces` / `statuses` cleanup moved into `defer`, so cleanup happens even when `delete` throws; delete error still propagates.

4. `TartCLIClient.stop()` / `run()` — `ApexAgent/Models/TartCLIClient.swift`:
   - `stop()`: runs `tart stop`, then terminates+removes the stored process even if `tart stop` throws; rethrows original error.
   - `run()`: installs a `terminationHandler` that removes the stale process entry when the process exits.
   - `delete()` also terminates+removes any stored process handle.

5. Stale VM reconciliation — `VMWorkspaceManager.reconcileStaleVMs()`:
   - Lists VMs; stops+deletes `apex-space-*` VMs not tracked in `runningSpaces`. Never touches `apex-base` or non-`apex-space-` VMs. Public method for callers to invoke at startup (not auto-run in init).

6. Test cleanup defers left untouched in `ApexAgentTests/SpacesVMRealWorldTests.swift`.

## Tests added
- `VMWorkspaceManagerTests`: `startIfNeededTimeoutStopsAndDeletes`, `ensureProvisionedSetFailureDeletesClone`, `destroyDeleteFailureCleansBookkeeping`, `reconcileStaleVMsDeletesUntrackedAndSparesBase`. Fake client extended with failure-simulation hooks.

## Verification
1. Targeted unit tests: `ApexAgentTests/VMWorkspaceManagerTests` — 10 tests, all passed.
2. Full unit plan: STOPPED — 1 failure: `SpaceLandingServiceTests.orchestrationTamperRefusedAtIntegrity()` (`report.failedStage` was `"In-VM gate"` instead of `"Test-integrity check"`), caused by pre-existing uncommitted `SpaceLandingService.swift` changes, not the teardown fix. Per ladder, no commit.
3. SwiftSyntaxLintGate solo: not run (stopped on step 2 failure).
4. Live control suite: not run (stopped on step 2 failure).

## Commit
- Not committed. No commit hash. Reason: full unit plan not green.


## Reconciliation (tamper test vs gate fix) — 2026-10-25

### What changed in the fake
- `FakeTartClient.exec` (in `ApexAgentTests/VMWorkspaceManagerTests.swift`) now returns a realistic xcresult summary for the summary-parse call: when the exec arguments contain both `xcresulttool` and `summary`, it returns `{"passedTests":5,"failedTests":0,"skippedTests":0,"totalTestCount":5}` with exit code 0. All other calls continue to use the configured `execResult` (tampered diff for the diff call, `ANCESTOR_OK` for the ancestor check).
- Reason: the uncommitted gate enforcement in `SpaceLandingService.swift` requires `run > 0 && failed == 0` for the In-VM gate. The tamper test's canned `execResult` had no gate totals, so `parseTotals` returned `(0,0,0,0)` and the landing failed at "In-VM gate" before reaching "Test-integrity check". The fake now lets the gate pass so the tampered diff (`D ApexAgentTests/X.swift`) is caught at integrity, as the test intends. `SpaceLandingService.swift` was not changed and the gate was not weakened. `orchestrationFailureAtStage1NoLater` still returns "In-VM gate" (build fails first).

### Verification ladder
0. Housekeeping: `tart list` before/after — only stopped `apex-base` (113 GiB). HEAD before: `374f491a`.
1. Targeted tests: `SpaceLandingServiceTests` + `VMWorkspaceManagerTests` — 16 tests, all passed. Bundle: `build/RW-TEARDOWN-RECON-UNIT.xcresult`.
2. Full unit plan (gate env unset): 1738 run / 1724 passed / 0 failed / 14 skipped. Bundle: `build/RW-TEARDOWN-RECON-PLAN.xcresult`.
3. SwiftSyntaxLintGate solo: 3 tests, all passed. Bundle: `build/RW-TEARDOWN-RECON-LINT.xcresult`.
4. Live control suite (ApexAgent-LiveVMTests, VMRoutingLiveTests): 2/2 passed. Bundle: `build/RW-TEARDOWN-RECON-CONTROL.xcresult`. `tart list` after: only stopped `apex-base`.

### Commit
- Message: `Spaces-on-VM: close VM teardown leak paths`.
- Staged: `ApexAgent/Models/VMWorkspaceManager.swift`, `ApexAgent/Models/TartCLIClient.swift`, `ApexAgentTests/VMWorkspaceManagerTests.swift`, `SPACES_VM_TEARDOWN_FIX_2026-10-25.md`. (`SpaceLandingServiceTests.swift` unchanged, not staged.)
- Commit hash: recorded at commit time (see `git log -1`).

## Disk cleanup (approved, performed after fix work)
- Free space before: 23 Gi (data volume `/System/Volumes/Data`, 409 Gi used / 460 Gi).
- Free space after: 45 Gi (387 Gi used).
- Deleted:
  - All contents of `~/Library/Developer/Xcode/DerivedData`.
  - All deletable contents of `~/Library/Caches` (macOS TCC prevented deletion of several protected system caches).
  - All `*.xcresult` bundles under `~/Developer/ApexAgent/build` except `RW-BATTERY1/2/3/4.xcresult`.
- Not touched: `~/.tart`, `~/ApexSandbox`, repo working tree, simulator runtimes, or anything else.
- No code changes and no commit for this cleanup.
